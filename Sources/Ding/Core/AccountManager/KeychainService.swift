import Foundation
import os
import Security

/// Errors encountered during Keychain operations.
public enum KeychainError: LocalizedError, Sendable, Equatable {
    /// The requested item was not found in the Keychain.
    case itemNotFound

    /// An item for this service and account identifier already exists.
    case duplicateItem

    /// Data retrieved from the Keychain could not be decoded as UTF-8.
    case invalidData

    /// An unhandled macOS Keychain Services status was returned.
    case unhandledStatus(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .itemNotFound:
            return "The requested credential was not found in the Keychain."
        case .duplicateItem:
            return "A credential for this account already exists in the Keychain."
        case .invalidData:
            return "The Keychain item contained invalid or corrupt data."
        case .unhandledStatus(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error"
            return "Keychain operation failed with status \(status): \(message)"
        }
    }
}

/// Protocol defining credential storage operations for mail accounts.
public protocol KeychainServiceProtocol: Sendable {
    /// Stores an app password for the given account identifier.
    ///
    /// - Parameters:
    ///   - password: The IMAP app password.
    ///   - id: The unique account identifier.
    /// - Throws: `KeychainError.duplicateItem` if already stored, or other `KeychainError`s on failure.
    func store(password: String, forAccountID id: UUID) throws

    /// Retrieves the app password for the given account identifier.
    ///
    /// - Parameter id: The unique account identifier.
    /// - Returns: The stored app password string.
    /// - Throws: `KeychainError.itemNotFound` if absent, or other `KeychainError`s on failure.
    func retrievePassword(forAccountID id: UUID) throws -> String

    /// Updates or inserts an app password for the given account identifier.
    ///
    /// - Parameters:
    ///   - password: The new app password.
    ///   - id: The unique account identifier.
    /// - Throws: `KeychainError` on failure.
    func updatePassword(_ password: String, forAccountID id: UUID) throws

    /// Deletes the app password for the given account identifier.
    ///
    /// - Parameter id: The unique account identifier.
    /// - Throws: `KeychainError.itemNotFound` if absent, or other `KeychainError`s on failure.
    func deletePassword(forAccountID id: UUID) throws
}

/// Manages secure credential storage in the macOS system Keychain.
///
/// ## Security Architecture & Privacy
/// This service is the **exclusive** storage location for user IMAP app passwords in ding.
/// Passwords stored here never touch `UserDefaults`, application support files (`accounts.json`),
/// or logging subsystems. Logging within this service strictly tracks operations and account IDs,
/// never credential values.
///
/// ## Accessibility Rationale (`kSecAttrAccessibleAfterFirstUnlock`)
/// We deliberately configure `kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock`.
///
/// Ding is a background menu bar utility that performs periodic mail polling and real-time push
/// notifications via IMAP IDLE. These background operations must continue executing reliably even
/// when the user locks their Mac or leaves their workstation unattended.
///
/// If we used `kSecAttrAccessibleWhenUnlocked`, background credential reads would fail or prompt
/// user authorization whenever the display locks. Conversely, `kSecAttrAccessibleAfterFirstUnlock`
/// ensures credentials remain accessible in the background once the user has unlocked the Mac
/// at least once post-boot, while maintaining complete encryption at rest before initial login.
public final class KeychainService: KeychainServiceProtocol, Sendable {
    private static let logger = Logger(subsystem: "com.ding.mac", category: "Keychain")

    /// Shared singleton instance of `KeychainService`.
    public static let shared = KeychainService()

    /// The Keychain service attribute name identifying ding IMAP credentials.
    public let serviceName: String

    /// Initializes a Keychain service instance.
    ///
    /// - Parameter serviceName: The service identifier. Defaults to `"com.ding.mac.imap-app-password"`.
    public init(serviceName: String = "com.ding.mac.imap-app-password") {
        self.serviceName = serviceName
    }

    /// Stores a new app password in the Keychain.
    public func store(password: String, forAccountID id: UUID) throws {
        Self.logger.debug("Storing password in Keychain for account: \(id.uuidString, privacy: .public)")

        let passwordData = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: id.uuidString,
            kSecValueData as String: passwordData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            Self.logger.error("Failed to store password for account \(id.uuidString, privacy: .public): status \(status)")
            if status == errSecDuplicateItem {
                throw KeychainError.duplicateItem
            }
            throw KeychainError.unhandledStatus(status)
        }

        Self.logger.info("Successfully stored password for account \(id.uuidString, privacy: .public)")
    }

    /// Retrieves an app password from the Keychain.
    public func retrievePassword(forAccountID id: UUID) throws -> String {
        Self.logger.debug("Retrieving password from Keychain for account: \(id.uuidString, privacy: .public)")

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                Self.logger.warning("Password not found in Keychain for account: \(id.uuidString, privacy: .public)")
                throw KeychainError.itemNotFound
            }
            Self.logger.error("Failed to retrieve password for account \(id.uuidString, privacy: .public): status \(status)")
            throw KeychainError.unhandledStatus(status)
        }

        guard let data = item as? Data, let password = String(data: data, encoding: .utf8) else {
            Self.logger.error("Failed to decode password data for account: \(id.uuidString, privacy: .public)")
            throw KeychainError.invalidData
        }

        return password
    }

    /// Updates an existing password or stores it if it does not yet exist.
    public func updatePassword(_ password: String, forAccountID id: UUID) throws {
        Self.logger.debug("Updating password in Keychain for account: \(id.uuidString, privacy: .public)")

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: id.uuidString
        ]

        let passwordData = Data(password.utf8)
        let attributesToUpdate: [String: Any] = [
            kSecValueData as String: passwordData
        ]

        let status = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
        if status == errSecItemNotFound {
            Self.logger.info("Password not found on update, inserting new item for account: \(id.uuidString, privacy: .public)")
            try store(password: password, forAccountID: id)
            return
        }

        guard status == errSecSuccess else {
            Self.logger.error("Failed to update password for account \(id.uuidString, privacy: .public): status \(status)")
            throw KeychainError.unhandledStatus(status)
        }

        Self.logger.info("Successfully updated password for account: \(id.uuidString, privacy: .public)")
    }

    /// Deletes a password from the Keychain.
    public func deletePassword(forAccountID id: UUID) throws {
        Self.logger.debug("Deleting password from Keychain for account: \(id.uuidString, privacy: .public)")

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: id.uuidString
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                Self.logger.warning("Password not found to delete for account: \(id.uuidString, privacy: .public)")
                throw KeychainError.itemNotFound
            }
            Self.logger.error("Failed to delete password for account \(id.uuidString, privacy: .public): status \(status)")
            throw KeychainError.unhandledStatus(status)
        }

        Self.logger.info("Successfully deleted password for account: \(id.uuidString, privacy: .public)")
    }
}
