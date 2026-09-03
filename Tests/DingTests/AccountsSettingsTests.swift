import XCTest
@testable import ding

final class AccountsSettingsTests: XCTestCase {
    private var tempDirectoryURL: URL!
    private var testStore: AccountStore!
    private var mockKeychain: InMemoryKeychainService!

    override func setUp() {
        super.setUp()
        tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ding-ui-tests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = tempDirectoryURL.appendingPathComponent("accounts.json")
        testStore = AccountStore(fileURL: fileURL)
        mockKeychain = InMemoryKeychainService()
    }

    override func tearDown() {
        if let tempDirectoryURL = tempDirectoryURL {
            try? FileManager.default.removeItem(at: tempDirectoryURL)
        }
        super.tearDown()
    }

    @MainActor
    func testSetNeedsReauthenticationSuccess() throws {
        let manager = AccountManager(accountStore: testStore, keychainService: mockKeychain)
        let account = try manager.addAccount(
            email: "bob@gmail.com",
            provider: .gmail,
            appPassword: "secret-password",
            alias: "Main"
        )

        XCTAssertFalse(manager.accounts[0].needsReauthentication)

        // Set to true
        try manager.setNeedsReauthentication(forAccountID: account.id, needsReauthentication: true)
        XCTAssertTrue(manager.accounts[0].needsReauthentication)

        // Verify persisted to disk
        let reloaded = try testStore.load()
        XCTAssertTrue(reloaded[0].needsReauthentication)

        // Clear flag
        try manager.setNeedsReauthentication(forAccountID: account.id, needsReauthentication: false)
        XCTAssertFalse(manager.accounts[0].needsReauthentication)

        let reloadedAfterClear = try testStore.load()
        XCTAssertFalse(reloadedAfterClear[0].needsReauthentication)
    }

    @MainActor
    func testSetNeedsReauthenticationNonExistentAccountThrows() {
        let manager = AccountManager(accountStore: testStore, keychainService: mockKeychain)
        let missingID = UUID()

        XCTAssertThrowsError(try manager.setNeedsReauthentication(forAccountID: missingID, needsReauthentication: true)) { error in
            XCTAssertEqual(error as? AccountManagerError, .accountNotFound(missingID))
        }
    }

    @MainActor
    func testVerificationFlowWithFakeIMAPClientSuccess() async throws {
        let manager = AccountManager(accountStore: testStore, keychainService: mockKeychain)
        let fakeClient = FakeIMAPClient()

        // Simulate AddAccountView verification logic:
        let email = "user@fastmail.com"
        let password = "valid-app-password"
        guard let provider = MailProvider.detect(fromEmail: email) else {
            XCTFail("Provider detection failed")
            return
        }

        try await fakeClient.connect(host: provider.imapHost, port: provider.imapPort)
        try await fakeClient.login(email: email, password: password)
        await fakeClient.disconnect()

        let created = try manager.addAccount(email: email, provider: provider, appPassword: password, alias: "Fastmail")

        let connectCount = await fakeClient.connectCallCount
        let loginCount = await fakeClient.loginCallCount
        let disconnectCount = await fakeClient.disconnectCallCount
        let lastHost = await fakeClient.lastConnectedHost

        XCTAssertEqual(connectCount, 1)
        XCTAssertEqual(loginCount, 1)
        XCTAssertEqual(disconnectCount, 1)
        XCTAssertEqual(lastHost, "imap.fastmail.com")
        XCTAssertEqual(manager.accounts.count, 1)
        XCTAssertEqual(manager.accounts.first?.id, created.id)
    }

    @MainActor
    func testVerificationFlowWithFakeIMAPClientAuthFailure() async throws {
        let manager = AccountManager(accountStore: testStore, keychainService: mockKeychain)
        let fakeClient = FakeIMAPClient(loginError: .authenticationFailed)

        let email = "user@gmail.com"
        let password = "bad-password"
        guard let provider = MailProvider.detect(fromEmail: email) else {
            XCTFail("Provider detection failed")
            return
        }

        var caughtError: IMAPClientError?
        do {
            try await fakeClient.connect(host: provider.imapHost, port: provider.imapPort)
            try await fakeClient.login(email: email, password: password)
            await fakeClient.disconnect()
            try manager.addAccount(email: email, provider: provider, appPassword: password)
        } catch let error as IMAPClientError {
            await fakeClient.disconnect()
            caughtError = error
        }

        let disconnectCount = await fakeClient.disconnectCallCount
        XCTAssertEqual(caughtError, .authenticationFailed)
        XCTAssertEqual(disconnectCount, 1)
        // Ensure account was NOT added
        XCTAssertTrue(manager.accounts.isEmpty)
    }

    @MainActor
    func testVerificationFlowWithFakeIMAPClientConnectionFailure() async throws {
        let manager = AccountManager(accountStore: testStore, keychainService: mockKeychain)
        let fakeClient = FakeIMAPClient(connectError: .connectionFailed(underlying: NSError(domain: "NSPOSIXErrorDomain", code: 61)))

        let email = "user@icloud.com"
        let password = "some-password"
        guard let provider = MailProvider.detect(fromEmail: email) else {
            XCTFail("Provider detection failed")
            return
        }

        var caughtError: IMAPClientError?
        do {
            try await fakeClient.connect(host: provider.imapHost, port: provider.imapPort)
            try await fakeClient.login(email: email, password: password)
            await fakeClient.disconnect()
            try manager.addAccount(email: email, provider: provider, appPassword: password)
        } catch let error as IMAPClientError {
            await fakeClient.disconnect()
            caughtError = error
        }

        XCTAssertNotNil(caughtError)
        XCTAssertTrue(manager.accounts.isEmpty)
    }

    @MainActor
    func testAccountsSettingsViewAndAddAccountViewInstantiation() {
        let manager = AccountManager(accountStore: testStore, keychainService: mockKeychain)

        // Verify views instantiate cleanly with custom factories
        let settingsView = AccountsSettingsView(
            accountManager: manager,
            imapClientFactory: { _ in FakeIMAPClient() }
        )
        XCTAssertNotNil(settingsView.body)

        let addAccountView = AddAccountView(
            accountManager: manager,
            imapClientFactory: { _ in FakeIMAPClient() }
        )
        XCTAssertNotNil(addAccountView.body)
    }
}
