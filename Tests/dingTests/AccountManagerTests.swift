import XCTest
@testable import ding

private final class FailingAccountStore: AccountStoreProtocol, @unchecked Sendable {
    func load() throws -> [Account] {
        []
    }

    func save(_ accounts: [Account]) throws {
        throw AccountStoreError.writeFailed(NSError(domain: "test", code: -1))
    }
}

final class AccountManagerTests: XCTestCase {
    private var tempDirectoryURL: URL!
    private var testStore: AccountStore!
    private var mockKeychain: InMemoryKeychainService!
    private var testSyncStore: SyncStateStore!

    override func setUp() {
        super.setUp()
        tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ding-acc-tests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = tempDirectoryURL.appendingPathComponent("accounts.json")
        let syncFileURL = tempDirectoryURL.appendingPathComponent("sync_state.json")
        testStore = AccountStore(fileURL: fileURL)
        mockKeychain = InMemoryKeychainService()
        testSyncStore = SyncStateStore(fileURL: syncFileURL)
    }

    override func tearDown() {
        if let tempDirectoryURL = tempDirectoryURL {
            try? FileManager.default.removeItem(at: tempDirectoryURL)
        }
        super.tearDown()
    }

    @MainActor
    func testAddAccountSuccess() throws {
        let manager = AccountManager(accountStore: testStore, keychainService: mockKeychain)
        XCTAssertTrue(manager.accounts.isEmpty)

        let created = try manager.addAccount(
            email: "alice@gmail.com",
            provider: .gmail,
            appPassword: "app-password-xyz",
            alias: "Work"
        )

        // Verify in-memory state
        XCTAssertEqual(manager.accounts.count, 1)
        XCTAssertEqual(manager.accounts.first?.id, created.id)
        XCTAssertEqual(manager.accounts.first?.email, "alice@gmail.com")
        XCTAssertEqual(manager.accounts.first?.provider, .gmail)
        XCTAssertEqual(manager.accounts.first?.alias, "Work")

        // Verify Keychain contains password
        let storedPassword = try mockKeychain.retrievePassword(forAccountID: created.id)
        XCTAssertEqual(storedPassword, "app-password-xyz")

        // Verify disk store contains account
        let reloadedAccounts = try testStore.load()
        XCTAssertEqual(reloadedAccounts.count, 1)
        XCTAssertEqual(reloadedAccounts.first?.id, created.id)
    }

    @MainActor
    func testAddAccountValidation() throws {
        let manager = AccountManager(accountStore: testStore, keychainService: mockKeychain)

        // Empty email
        XCTAssertThrowsError(try manager.addAccount(email: "  ", provider: .gmail, appPassword: "pass")) { error in
            XCTAssertEqual(error as? AccountManagerError, .emptyEmail)
        }

        // Empty password
        XCTAssertThrowsError(try manager.addAccount(email: "test@gmail.com", provider: .gmail, appPassword: "   ")) { error in
            XCTAssertEqual(error as? AccountManagerError, .emptyPassword)
        }

        // Duplicate email
        try manager.addAccount(email: "user@gmail.com", provider: .gmail, appPassword: "pass1")
        XCTAssertThrowsError(try manager.addAccount(email: "USER@GMAIL.COM", provider: .gmail, appPassword: "pass2")) { error in
            XCTAssertEqual(error as? AccountManagerError, .duplicateAccount(email: "USER@GMAIL.COM"))
        }
    }

    @MainActor
    func testAddAccountRollbackOnDiskFailure() {
        let failingStore = FailingAccountStore()
        let manager = AccountManager(accountStore: failingStore, keychainService: mockKeychain)

        XCTAssertThrowsError(try manager.addAccount(email: "bob@yahoo.com", provider: .yahoo, appPassword: "pass")) { error in
            XCTAssertTrue(error is AccountStoreError)
        }

        // Ensure in-memory list remains empty
        XCTAssertTrue(manager.accounts.isEmpty)
    }

    @MainActor
    func testRemoveAccountSuccess() throws {
        let manager = AccountManager(
            accountStore: testStore,
            keychainService: mockKeychain,
            syncStateStore: testSyncStore
        )
        let account = try manager.addAccount(email: "user@icloud.com", provider: .icloud, appPassword: "password123")

        // Seed sync state for the account
        let state = SyncState(accountID: account.id, uidValidity: 1, lastSeenUID: 50, lastSyncedAt: Date())
        try testSyncStore.updateState(state)
        XCTAssertNotNil(try testSyncStore.state(forAccountID: account.id))

        XCTAssertEqual(manager.accounts.count, 1)

        try manager.removeAccount(id: account.id)

        // Verified removed from memory
        XCTAssertTrue(manager.accounts.isEmpty)

        // Verified removed from store
        let persisted = try testStore.load()
        XCTAssertTrue(persisted.isEmpty)

        // Verified removed from Keychain
        XCTAssertThrowsError(try mockKeychain.retrievePassword(forAccountID: account.id)) { error in
            XCTAssertEqual(error as? KeychainError, .itemNotFound)
        }

        // Verified removed from SyncStateStore
        XCTAssertNil(try testSyncStore.state(forAccountID: account.id))
    }

    @MainActor
    func testRemoveNonExistentAccountThrows() {
        let manager = AccountManager(accountStore: testStore, keychainService: mockKeychain)
        let missingID = UUID()

        XCTAssertThrowsError(try manager.removeAccount(id: missingID)) { error in
            XCTAssertEqual(error as? AccountManagerError, .accountNotFound(missingID))
        }
    }

    @MainActor
    func testUpdateAccountSuccess() throws {
        let manager = AccountManager(accountStore: testStore, keychainService: mockKeychain)
        let original = try manager.addAccount(email: "carol@fastmail.com", provider: .fastmail, appPassword: "pass")

        var modified = original
        modified.alias = "Fastmail Primary"
        modified.syncFrequency = .fifteenMinutes
        modified.notificationClickBehavior = .openMailApp

        try manager.updateAccount(modified)

        // Verify in-memory update
        XCTAssertEqual(manager.accounts.first?.alias, "Fastmail Primary")
        XCTAssertEqual(manager.accounts.first?.syncFrequency, .fifteenMinutes)
        XCTAssertEqual(manager.accounts.first?.notificationClickBehavior, .openMailApp)

        // Verify disk store update
        let reloaded = try testStore.load()
        XCTAssertEqual(reloaded.first?.alias, "Fastmail Primary")
        XCTAssertEqual(reloaded.first?.syncFrequency, .fifteenMinutes)
        XCTAssertEqual(reloaded.first?.notificationClickBehavior, .openMailApp)

        // Verify password in Keychain was untouched
        XCTAssertEqual(try mockKeychain.retrievePassword(forAccountID: original.id), "pass")
    }

    @MainActor
    func testUpdateNonExistentAccountThrows() {
        let manager = AccountManager(accountStore: testStore, keychainService: mockKeychain)
        let missingAccount = Account(id: UUID(), email: "nobody@gmail.com", provider: .gmail)

        XCTAssertThrowsError(try manager.updateAccount(missingAccount)) { error in
            XCTAssertEqual(error as? AccountManagerError, .accountNotFound(missingAccount.id))
        }
    }

    @MainActor
    func testUpdatePasswordSuccess() throws {
        let manager = AccountManager(accountStore: testStore, keychainService: mockKeychain)
        let account = try manager.addAccount(email: "dave@outlook.com", provider: .outlook, appPassword: "initial-pass")

        try manager.updatePassword(forAccountID: account.id, newPassword: "renewed-pass")

        let currentPassword = try manager.password(forAccountID: account.id)
        XCTAssertEqual(currentPassword, "renewed-pass")
    }

    @MainActor
    func testUpdatePasswordErrors() throws {
        let manager = AccountManager(accountStore: testStore, keychainService: mockKeychain)
        let account = try manager.addAccount(email: "eve@gmail.com", provider: .gmail, appPassword: "old")
        let missingID = UUID()

        // Empty new password
        XCTAssertThrowsError(try manager.updatePassword(forAccountID: account.id, newPassword: "   ")) { error in
            XCTAssertEqual(error as? AccountManagerError, .emptyPassword)
        }

        // Non-existent account
        XCTAssertThrowsError(try manager.updatePassword(forAccountID: missingID, newPassword: "new")) { error in
            XCTAssertEqual(error as? AccountManagerError, .accountNotFound(missingID))
        }
    }

    @MainActor
    func testPasswordRetrievalErrors() {
        let manager = AccountManager(accountStore: testStore, keychainService: mockKeychain)
        let missingID = UUID()

        XCTAssertThrowsError(try manager.password(forAccountID: missingID)) { error in
            XCTAssertEqual(error as? AccountManagerError, .accountNotFound(missingID))
        }
    }

    // MARK: - In-Memory Password Cache Tests (Issue #16)

    @MainActor
    func testPasswordCacheHitAvoidsRepeatedKeychainReads() throws {
        let manager = AccountManager(accountStore: testStore, keychainService: mockKeychain)
        let account = try manager.addAccount(email: "cache-user@example.com", provider: .gmail, appPassword: "cached-secret")

        // First call: cache miss, reads from Keychain
        let firstPassword = try manager.password(forAccountID: account.id)
        XCTAssertEqual(firstPassword, "cached-secret")
        XCTAssertEqual(mockKeychain.retrieveCalls(forAccountID: account.id), 1)

        // Second call: cache hit, must NOT invoke Keychain retrieve again
        let secondPassword = try manager.password(forAccountID: account.id)
        XCTAssertEqual(secondPassword, "cached-secret")
        XCTAssertEqual(mockKeychain.retrieveCalls(forAccountID: account.id), 1)

        // Third call: still cached
        let thirdPassword = try manager.password(forAccountID: account.id)
        XCTAssertEqual(thirdPassword, "cached-secret")
        XCTAssertEqual(mockKeychain.retrieveCalls(forAccountID: account.id), 1)
    }

    @MainActor
    func testPasswordCacheInvalidatedOnAccountDeletion() throws {
        let manager = AccountManager(accountStore: testStore, keychainService: mockKeychain)
        let account = try manager.addAccount(email: "delete-cache@example.com", provider: .gmail, appPassword: "delete-me")

        // Populate cache
        let initial = try manager.password(forAccountID: account.id)
        XCTAssertEqual(initial, "delete-me")
        XCTAssertEqual(mockKeychain.retrieveCalls(forAccountID: account.id), 1)

        // Delete account
        try manager.removeAccount(id: account.id)

        // Retrieval now throws accountNotFound, and cache was cleared
        XCTAssertThrowsError(try manager.password(forAccountID: account.id)) { error in
            XCTAssertEqual(error as? AccountManagerError, .accountNotFound(account.id))
        }
    }

    @MainActor
    func testPasswordCacheInvalidatedOnCredentialUpdate() throws {
        let manager = AccountManager(accountStore: testStore, keychainService: mockKeychain)
        let account = try manager.addAccount(email: "update-cache@example.com", provider: .outlook, appPassword: "first-secret")

        // Populate cache
        let first = try manager.password(forAccountID: account.id)
        XCTAssertEqual(first, "first-secret")
        XCTAssertEqual(mockKeychain.retrieveCalls(forAccountID: account.id), 1)

        // Update password in manager
        try manager.updatePassword(forAccountID: account.id, newPassword: "updated-secret")

        // Next password retrieval must re-read from Keychain to avoid returning stale credentials
        let second = try manager.password(forAccountID: account.id)
        XCTAssertEqual(second, "updated-secret")
        XCTAssertEqual(mockKeychain.retrieveCalls(forAccountID: account.id), 2)

        // Subsequent call hits the newly populated cache
        let third = try manager.password(forAccountID: account.id)
        XCTAssertEqual(third, "updated-secret")
        XCTAssertEqual(mockKeychain.retrieveCalls(forAccountID: account.id), 2)
    }

    @MainActor
    func testFailedKeychainRetrievalIsNotCached() throws {
        let manager = AccountManager(accountStore: testStore, keychainService: mockKeychain)
        let account = try manager.addAccount(email: "retry@example.com", provider: .fastmail, appPassword: "valid-pass")

        // Simulate Keychain failure (e.g. user denied permission or system error)
        mockKeychain.errorToThrowOnRetrieve = KeychainError.unhandledStatus(errSecAuthFailed)

        // First attempt throws error
        XCTAssertThrowsError(try manager.password(forAccountID: account.id)) { error in
            XCTAssertEqual(error as? KeychainError, .unhandledStatus(errSecAuthFailed))
        }
        XCTAssertEqual(mockKeychain.retrieveCalls(forAccountID: account.id), 1)

        // Next call should retry Keychain rather than persisting a failure/nil state
        mockKeychain.errorToThrowOnRetrieve = nil

        let recovered = try manager.password(forAccountID: account.id)
        XCTAssertEqual(recovered, "valid-pass")
        XCTAssertEqual(mockKeychain.retrieveCalls(forAccountID: account.id), 2)

        // Now that it succeeded, subsequent calls are cached
        let cached = try manager.password(forAccountID: account.id)
        XCTAssertEqual(cached, "valid-pass")
        XCTAssertEqual(mockKeychain.retrieveCalls(forAccountID: account.id), 2)
    }
}
