import Combine
import Foundation
import os

/// Errors encountered during account management operations.
public enum AccountManagerError: LocalizedError, Sendable, Equatable {
    /// The account with the specified identifier was not found.
    case accountNotFound(UUID)

    /// An account with the same email address is already configured.
    case duplicateAccount(email: String)

    /// The provided email address was empty or invalid.
    case emptyEmail

    /// The provided app password was empty.
    case emptyPassword

    public var errorDescription: String? {
        switch self {
        case .accountNotFound(let id):
            return "Account with ID \(id.uuidString) was not found."
        case .duplicateAccount(let email):
            return "An account for \(email) already exists."
        case .emptyEmail:
            return "Email address cannot be empty."
        case .emptyPassword:
            return "App password cannot be empty."
        }
    }
}

/// Centralized observable manager for user mail accounts.
///
/// ## Concurrency & Observation Choice: `ObservableObject` vs `@Observable`
/// While Swift 5.9 introduced the `@Observable` macro in the `Observation` framework,
/// the framework requires macOS 14.0 or newer at runtime. Because ding specifies
/// a deployment target of macOS 13.0 (`platforms: [.macOS(.v13)]`), using `@Observable` causes
/// compilation failure (`'Observable()' is only available in macOS 14.0 or newer`).
///
/// Following the architecture established in `AppPreferences`, `AccountManager` conforms to Combine's
/// `ObservableObject` with `@Published` properties, bound strictly to `@MainActor`. In Swift 6 strict
/// concurrency, this guarantees thread safety across SwiftUI views and background services without data races.
@MainActor
public final class AccountManager: ObservableObject {
    private static let logger = Logger(subsystem: DingLog.subsystem, category: "AccountManager")

    /// The shared singleton instance of `AccountManager`.
    public static let shared = AccountManager()

    /// The observable list of configured accounts.
    @Published public private(set) var accounts: [Account] = []

    private let accountStore: AccountStoreProtocol
    private let keychainService: KeychainServiceProtocol
    private let syncStateStore: SyncStateStoreProtocol

    /// In-memory password cache keyed by account identifier.
    ///
    /// ## Rationale & Lifetime (Issue #16)
    /// Ding is a background menu bar utility that repeatedly polls IMAP or maintains an IDLE loop.
    /// In macOS, retrieving passwords from the legacy Keychain without "Always Allow" (or when an
    /// ad-hoc signature's Designated Requirement changes across builds) prompts the user for authorization
    /// on every `SecItemCopyMatching` call.
    ///
    /// To avoid prompting the user on every sync cycle / reconnect:
    /// - Passwords are cached in memory upon first successful retrieval in the current app session.
    /// - The cache is strictly process-lifetime: it is never written to disk, `UserDefaults`, or any
    ///   persistent store. On app termination, memory is cleared.
    /// - Entries are invalidated when an account is removed or when credentials are updated.
    /// - Failed Keychain lookups (e.g. auth denial or error) are never cached, ensuring future
    ///   attempts retry Keychain rather than persisting a broken/nil state.
    ///
    /// ## Concurrency & Thread Safety
    /// Because `AccountManager` is `@MainActor`-isolated, access to this dictionary is serialized on
    /// `@MainActor`. Background workers (such as `AccountSyncWorker`) access credentials via
    /// `AccountManager.password(forAccountID:)` using `MainActor.run`, eliminating data races under
    /// Swift 6 strict concurrency.
    private var passwordCache: [UUID: String] = [:]

    /// Initializes a new account manager.
    ///
    /// - Parameters:
    ///   - accountStore: The disk store for account metadata. Defaults to `AccountStore()`.
    ///   - keychainService: The credential store for account app passwords. Defaults to `KeychainService.shared`.
    ///   - syncStateStore: The disk store for account sync state. Defaults to `SyncStateStore()`.
    public init(
        accountStore: AccountStoreProtocol = AccountStore(),
        keychainService: KeychainServiceProtocol = KeychainService.shared,
        syncStateStore: SyncStateStoreProtocol = SyncStateStore()
    ) {
        self.accountStore = accountStore
        self.keychainService = keychainService
        self.syncStateStore = syncStateStore
        loadAccounts()
    }

    /// Loads accounts from disk into memory.
    private func loadAccounts() {
        do {
            self.accounts = try accountStore.load()
            Self.logger.info("Loaded \(self.accounts.count) accounts from disk.")
        } catch {
            Self.logger.error("Failed to load accounts from disk: \(error.localizedDescription, privacy: .public)")
            self.accounts = []
        }
    }

    /// Creates and persists a new mail account along with its credentials.
    ///
    /// - Parameters:
    ///   - email: The account email address.
    ///   - provider: The mail provider preset.
    ///   - appPassword: The IMAP app password for authentication.
    ///   - alias: An optional user-specified nickname.
    /// - Returns: The newly created and persisted `Account`.
    /// - Throws: `AccountManagerError`, `KeychainError`, or `AccountStoreError` on failure.
    @discardableResult
    public func addAccount(
        email: String,
        provider: MailProvider,
        appPassword: String,
        alias: String? = nil
    ) throws -> Account {
        let cleanedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedEmail.isEmpty else {
            throw AccountManagerError.emptyEmail
        }

        let cleanedPassword = appPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedPassword.isEmpty else {
            throw AccountManagerError.emptyPassword
        }

        if accounts.contains(where: { $0.email.caseInsensitiveCompare(cleanedEmail) == .orderedSame }) {
            throw AccountManagerError.duplicateAccount(email: cleanedEmail)
        }

        let finalAlias = Account.normalizeAlias(alias)

        let account = Account(
            email: cleanedEmail,
            provider: provider,
            alias: finalAlias
        )

        // 1. Store secret in Keychain first
        try keychainService.store(password: cleanedPassword, forAccountID: account.id)

        // 2. Add to in-memory state
        accounts.append(account)

        // 3. Persist updated accounts to disk
        do {
            try accountStore.save(accounts)
        } catch {
            // Roll back on disk save failure to prevent orphaned credentials
            accounts.removeAll { $0.id == account.id }
            try? keychainService.deletePassword(forAccountID: account.id)
            throw error
        }

        Self.logger.info("Successfully added account \(account.id.uuidString, privacy: .public) (\(account.email, privacy: .public))")
        return account
    }

    /// Removes an account and its stored credentials.
    ///
    /// - Parameter id: The unique identifier of the account to remove.
    /// - Throws: `AccountManagerError.accountNotFound` if absent, or storage errors on failure.
    public func removeAccount(id: UUID) throws {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else {
            throw AccountManagerError.accountNotFound(id)
        }

        let removed = accounts.remove(at: index)

        // Persist change to disk first
        do {
            try accountStore.save(accounts)
        } catch {
            // Rollback in-memory state
            accounts.insert(removed, at: index)
            throw error
        }

        // Delete credential from Keychain
        do {
            try keychainService.deletePassword(forAccountID: id)
        } catch KeychainError.itemNotFound {
            // If already missing from Keychain, proceed without error
            Self.logger.debug("Credential was already absent from Keychain for account: \(id.uuidString, privacy: .public)")
        } catch {
            Self.logger.error("Failed to delete Keychain password for account \(id.uuidString, privacy: .public): \(error.localizedDescription)")
            throw error
        }

        // Prune orphaned sync state from sync_state.json
        do {
            try syncStateStore.removeState(forAccountID: id)
        } catch {
            Self.logger.warning("Failed to remove sync state for account \(id.uuidString, privacy: .public): \(error.localizedDescription)")
        }

        passwordCache.removeValue(forKey: id)
        Self.logger.debug("Invalidated password cache for removed account \(id.uuidString, privacy: .public)")

        Self.logger.info("Successfully removed account \(id.uuidString, privacy: .public)")
    }

    /// Updates configuration metadata for an existing account (alias, frequency, notification click behavior).
    ///
    /// This method modifies only the non-secret metadata and does not affect the stored Keychain password.
    ///
    /// - Parameter account: The modified account model matching an existing account ID.
    /// - Throws: `AccountManagerError.accountNotFound` if absent, or `AccountStoreError` on failure.
    public func updateAccount(_ account: Account) throws {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else {
            throw AccountManagerError.accountNotFound(account.id)
        }

        let oldAccount = accounts[index]
        accounts[index] = account

        do {
            try accountStore.save(accounts)
        } catch {
            accounts[index] = oldAccount
            throw error
        }

        Self.logger.info("Successfully updated account metadata for \(account.id.uuidString, privacy: .public)")
    }

    /// Updates the stored app password in the Keychain for an existing account and invalidates the session cache.
    ///
    /// - Parameters:
    ///   - id: The unique account identifier.
    ///   - newPassword: The new app password.
    /// - Throws: `AccountManagerError.accountNotFound`, `AccountManagerError.emptyPassword`, or `KeychainError`.
    public func updatePassword(forAccountID id: UUID, newPassword: String) throws {
        guard accounts.contains(where: { $0.id == id }) else {
            throw AccountManagerError.accountNotFound(id)
        }

        let cleanedPassword = newPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedPassword.isEmpty else {
            throw AccountManagerError.emptyPassword
        }

        try keychainService.updatePassword(cleanedPassword, forAccountID: id)
        passwordCache.removeValue(forKey: id)
        Self.logger.debug("Invalidated password cache for updated credentials on account \(id.uuidString, privacy: .public)")
        Self.logger.info("Successfully updated Keychain password for account \(id.uuidString, privacy: .public)")
    }

    /// Updates the re-authentication requirement state for an existing account.
    ///
    /// - Parameters:
    ///   - id: The unique account identifier.
    ///   - needsReauthentication: Whether the account requires re-authentication.
    /// - Throws: `AccountManagerError.accountNotFound` if absent, or `AccountStoreError` on failure.
    public func setNeedsReauthentication(forAccountID id: UUID, needsReauthentication: Bool) throws {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else {
            throw AccountManagerError.accountNotFound(id)
        }

        var account = accounts[index]
        account.needsReauthentication = needsReauthentication
        try updateAccount(account)
    }

    /// Retrieves the stored app password for an account, utilizing the in-memory session cache.
    ///
    /// If the password has already been retrieved during this process run, the cached value is returned
    /// immediately to avoid repeated Keychain reads and authorization prompts (Issue #16).
    ///
    /// - Parameter id: The unique account identifier.
    /// - Returns: The decrypted app password string.
    /// - Throws: `AccountManagerError.accountNotFound` or `KeychainError`.
    public func password(forAccountID id: UUID) throws -> String {
        guard accounts.contains(where: { $0.id == id }) else {
            throw AccountManagerError.accountNotFound(id)
        }

        if let cachedPassword = passwordCache[id] {
            Self.logger.debug("Password cache hit for account \(id.uuidString, privacy: .public)")
            return cachedPassword
        }

        Self.logger.debug("Password cache miss for account \(id.uuidString, privacy: .public)")
        do {
            let retrievedPassword = try keychainService.retrievePassword(forAccountID: id)
            passwordCache[id] = retrievedPassword
            return retrievedPassword
        } catch {
            // Do not cache failures; next call should retry Keychain
            passwordCache.removeValue(forKey: id)
            throw error
        }
    }
}
