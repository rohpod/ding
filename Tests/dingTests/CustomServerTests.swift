import XCTest
@testable import ding

final class IMAPServerValidationTests: XCTestCase {
    private func validate(_ host: String, _ port: String = "993") throws -> IMAPServer {
        try IMAPServer.validated(host: host, port: port)
    }

    private func assertFails(_ host: String, _ port: String = "993", with expected: IMAPServer.ValidationError, line: UInt = #line) {
        XCTAssertThrowsError(try validate(host, port), line: line) { error in
            XCTAssertEqual(error as? IMAPServer.ValidationError, expected, line: line)
        }
    }

    func testHostIsTrimmedLowercasedAndLosesTrailingDot() throws {
        XCTAssertEqual(try validate("  Mail.Example.COM. "), IMAPServer(host: "mail.example.com", port: 993))
    }

    func testEmptyHostIsRequired() {
        assertFails("", with: .hostRequired)
        assertFails("   ", with: .hostRequired)
        assertFails(".", with: .hostRequired)
    }

    func testSchemeSlashPortAndSpacesAreRejectedWithAHint() {
        assertFails("imaps://mail.example.com", with: .hostNotJustAName)
        assertFails("mail.example.com:993", with: .hostNotJustAName)
        assertFails("mail example.com", with: .hostNotJustAName)
        assertFails("::1", with: .hostNotJustAName)
        XCTAssertEqual(IMAPServer.ValidationError.hostNotJustAName.errorDescription, "Enter just the server name, e.g. mail.example.com.")
    }

    func testNonASCIIHostIsRejected() {
        assertFails("mäil.example.com", with: .hostNotASCII)
    }

    func testIPv4LiteralIsRejected() {
        assertFails("192.168.1.10", with: .hostIsIPAddress)
        XCTAssertEqual(IMAPServer.ValidationError.hostIsIPAddress.errorDescription, "Enter the server's name, not its IP address.")
    }

    func testPortMustBeNumericAndInRange() throws {
        assertFails("mail.example.com", "abc", with: .portInvalid)
        assertFails("mail.example.com", "", with: .portInvalid)
        assertFails("mail.example.com", "0", with: .portInvalid)
        assertFails("mail.example.com", "65536", with: .portInvalid)
        XCTAssertEqual(try validate("mail.example.com", " 1993 ").port, 1993)
        XCTAssertEqual(try validate("mail.example.com", "65535").port, 65535)
    }

    func testPort143ExplainsSTARTTLS() {
        assertFails("mail.example.com", "143", with: .portNeedsSTARTTLS)
        XCTAssertEqual(
            IMAPServer.ValidationError.portNeedsSTARTTLS.errorDescription,
            "Port 143 needs STARTTLS, which ding doesn't support. Try 993."
        )
    }
}

final class CustomAccountModelTests: XCTestCase {
    private let server = IMAPServer(host: "mail.corp.example", port: 1993)

    private func roundTrip(_ account: Account) throws -> Account {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Account.self, from: encoder.encode(account))
    }

    func testRoundTripWithCustomServerAndUsername() throws {
        let account = Account(email: "me@corp.example", provider: .custom, customServer: server, username: "me")
        let decoded = try roundTrip(account)
        XCTAssertEqual(decoded, account)
        XCTAssertEqual(decoded.customServer, server)
        XCTAssertEqual(decoded.username, "me")
    }

    func testPresetAccountSerializesWithoutTheNewKeys() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = try XCTUnwrap(String(data: encoder.encode(Account(email: "a@gmail.com", provider: .gmail)), encoding: .utf8))
        XCTAssertFalse(json.contains("customServer"))
        XCTAssertFalse(json.contains("username"))
    }

    func testOldFileWithoutNewKeysStillDecodes() throws {
        let json = """
        {"id":"\(UUID().uuidString)","email":"old@gmail.com","provider":"gmail","syncFrequency":"always",\
        "notificationClickBehavior":"useDefault","needsReauthentication":false,"includeInManualCheck":true,\
        "dateAdded":"2025-01-01T00:00:00Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let account = try decoder.decode(Account.self, from: Data(json.utf8))
        XCTAssertNil(account.customServer)
        XCTAssertNil(account.username)
        XCTAssertEqual(account.server, MailProvider.gmail.presetServer)
    }

    func testEqualityDistinguishesServerAndUsername() {
        let id = UUID()
        let date = Date()
        let base = Account(id: id, email: "a@corp.example", provider: .custom, dateAdded: date, customServer: server)
        XCTAssertEqual(base, Account(id: id, email: "a@corp.example", provider: .custom, dateAdded: date, customServer: server))
        XCTAssertNotEqual(base, Account(id: id, email: "a@corp.example", provider: .custom, dateAdded: date, customServer: IMAPServer(host: "other.example", port: 993)))
        XCTAssertNotEqual(base, Account(id: id, email: "a@corp.example", provider: .custom, dateAdded: date, customServer: server, username: "a"))
    }

    func testServerAndLoginNameForPresetAndCustom() {
        let preset = Account(email: "a@gmail.com", provider: .gmail)
        XCTAssertEqual(preset.server, IMAPServer(host: "imap.gmail.com", port: 993))
        XCTAssertEqual(preset.loginName, "a@gmail.com")
        XCTAssertEqual(preset.credentialName, "app password")

        let custom = Account(email: "a@corp.example", provider: .custom, customServer: server, username: "a")
        XCTAssertEqual(custom.server, server)
        XCTAssertEqual(custom.loginName, "a")
        XCTAssertEqual(custom.credentialName, "password")
        XCTAssertEqual(Account(email: "a@corp.example", provider: .custom, customServer: server).loginName, "a@corp.example")
    }

    func testCustomAccountWithoutServerFallsBackToEmptyHostInsteadOfFailingDecode() throws {
        let broken = Account(email: "a@corp.example", provider: .custom)
        XCTAssertEqual(broken.server.host, "")
        XCTAssertNoThrow(try roundTrip(broken), "One hand-edited record must not quarantine every account")
    }

    func testNormalizeUsername() {
        XCTAssertNil(Account.normalizeUsername(nil, email: "a@b.com"))
        XCTAssertNil(Account.normalizeUsername("   ", email: "a@b.com"))
        XCTAssertNil(Account.normalizeUsername("A@B.com", email: "a@b.com"))
        XCTAssertEqual(Account.normalizeUsername("  jdoe ", email: "a@b.com"), "jdoe")
    }
}

final class CustomAccountManagerTests: XCTestCase {
    private var tempDirectoryURL: URL!
    private var testStore: AccountStore!
    private var mockKeychain: InMemoryKeychainService!

    override func setUp() {
        super.setUp()
        tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ding-custom-tests-\(UUID().uuidString)", isDirectory: true)
        testStore = AccountStore(fileURL: tempDirectoryURL.appendingPathComponent("accounts.json"))
        mockKeychain = InMemoryKeychainService()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectoryURL)
        super.tearDown()
    }

    @MainActor
    func testAddCustomAccountStoresServerAndNormalizedUsername() throws {
        let manager = AccountManager(accountStore: testStore, keychainService: mockKeychain)
        let server = IMAPServer(host: "mail.corp.example", port: 993)

        let account = try manager.addAccount(
            email: "me@corp.example", provider: .custom, appPassword: "pw",
            customServer: server, username: "  jdoe "
        )

        XCTAssertEqual(account.customServer, server)
        XCTAssertEqual(account.username, "jdoe")
        XCTAssertEqual(manager.accounts.first, account)
    }

    @MainActor
    func testUsernameEqualToEmailOrEmptyIsDropped() throws {
        let manager = AccountManager(accountStore: testStore, keychainService: mockKeychain)
        let server = IMAPServer(host: "mail.corp.example", port: 993)

        let same = try manager.addAccount(email: "a@corp.example", provider: .custom, appPassword: "pw", customServer: server, username: "A@corp.example")
        let empty = try manager.addAccount(email: "b@corp.example", provider: .custom, appPassword: "pw", customServer: server, username: "  ")

        XCTAssertNil(same.username)
        XCTAssertNil(empty.username)
    }

    @MainActor
    func testCustomWithoutServerThrowsMissingServer() {
        let manager = AccountManager(accountStore: testStore, keychainService: mockKeychain)
        XCTAssertThrowsError(try manager.addAccount(email: "a@corp.example", provider: .custom, appPassword: "pw")) { error in
            XCTAssertEqual(error as? AccountManagerError, .missingServer)
        }
        XCTAssertTrue(manager.accounts.isEmpty)
    }

    @MainActor
    func testPresetAccountIgnoresACustomServer() throws {
        let manager = AccountManager(accountStore: testStore, keychainService: mockKeychain)
        let account = try manager.addAccount(
            email: "me@company.com", provider: .gmail, appPassword: "pw",
            customServer: IMAPServer(host: "elsewhere.example", port: 993)
        )
        XCTAssertNil(account.customServer, "A Workspace address on the Gmail preset still uses Gmail's server")
        XCTAssertEqual(account.server.host, "imap.gmail.com")
    }
}

final class AddAccountFormStateTests: XCTestCase {
    func testDetectionFollowsEmailUntilOverridden() {
        var form = AddAccountFormState()
        form.email = "me@gmail.com"
        XCTAssertEqual(form.effectiveProvider, .gmail)

        form.email = "me@icloud.com"
        XCTAssertEqual(form.effectiveProvider, .icloud)
    }

    func testOverrideSurvivesEmailEdits() {
        var form = AddAccountFormState()
        form.email = "me@company.com"
        XCTAssertNil(form.effectiveProvider)

        form.providerOverride = .gmail
        form.email = "me@company.co"
        form.email = "other@company.com"
        XCTAssertEqual(form.effectiveProvider, .gmail, "Picking Gmail for a Workspace address must stick")
    }

    func testCanContinueMatrix() {
        var form = AddAccountFormState()
        XCTAssertFalse(form.canContinue)

        form.email = "me@gmail.com"
        XCTAssertFalse(form.canContinue, "No password yet")
        form.password = "  "
        XCTAssertFalse(form.canContinue, "Whitespace is not a password")
        form.password = "pw"
        XCTAssertTrue(form.canContinue)

        form.email = "not-an-address"
        XCTAssertFalse(form.canContinue)

        form.email = "me@company.com"
        XCTAssertFalse(form.canContinue, "Unknown provider and none chosen")
        form.providerOverride = .gmail
        XCTAssertTrue(form.canContinue)
    }

    func testCustomNeedsAValidServer() {
        var form = AddAccountFormState()
        form.email = "me@company.com"
        form.password = "pw"
        form.providerOverride = .custom
        XCTAssertFalse(form.canContinue)
        XCTAssertNil(form.serverValidationMessage, "No error before the host is typed")

        form.host = "imaps://mail.company.com"
        XCTAssertFalse(form.canContinue)
        XCTAssertNotNil(form.serverValidationMessage)

        form.host = "Mail.Company.com"
        XCTAssertTrue(form.canContinue)
        XCTAssertEqual(form.server, IMAPServer(host: "mail.company.com", port: 993))

        form.port = "143"
        XCTAssertFalse(form.canContinue)
        XCTAssertEqual(form.serverValidationMessage, IMAPServer.ValidationError.portNeedsSTARTTLS.errorDescription)
    }

    func testPresetIgnoresCustomServerFields() {
        var form = AddAccountFormState()
        form.email = "me@gmail.com"
        form.password = "pw"
        form.host = "garbage:::"
        form.username = "someone"
        XCTAssertTrue(form.canContinue)
        XCTAssertEqual(form.server, MailProvider.gmail.presetServer)
        XCTAssertEqual(form.loginName, "me@gmail.com", "A username applies only to custom servers")
        XCTAssertNil(form.serverValidationMessage)
    }

    func testLoginNameUsesUsernameForCustomOnly() {
        var form = AddAccountFormState()
        form.email = "me@company.com"
        form.providerOverride = .custom
        XCTAssertEqual(form.loginName, "me@company.com")
        form.username = " jdoe "
        XCTAssertEqual(form.loginName, "jdoe")
        form.username = "ME@company.com"
        XCTAssertEqual(form.loginName, "me@company.com")
    }
}

final class AccountVerifierTests: XCTestCase {
    private let server = IMAPServer(host: "mail.corp.example", port: 1993)

    func testSuccessConnectsLogsInSelectsAndDisconnects() async throws {
        let client = FakeIMAPClient()
        try await AccountVerifier.verify(client: client, server: server, loginName: "jdoe", password: "pw")

        let connects = await client.connectCallCount
        let logins = await client.loginCallCount
        let selects = await client.selectInboxCallCount
        let disconnects = await client.disconnectCallCount
        let host = await client.lastConnectedHost
        let port = await client.lastConnectedPort
        let login = await client.lastLoginEmail
        XCTAssertEqual([connects, logins, selects, disconnects], [1, 1, 1, 1])
        XCTAssertEqual(host, "mail.corp.example")
        XCTAssertEqual(port, 1993)
        XCTAssertEqual(login, "jdoe")
    }

    func testDisconnectsOnConnectFailure() async {
        let client = FakeIMAPClient(connectError: .timeout)
        await assertFailsAndDisconnects(client)
        let logins = await client.loginCallCount
        XCTAssertEqual(logins, 0)
    }

    func testDisconnectsOnLoginFailure() async {
        let client = FakeIMAPClient(loginError: .authenticationFailed)
        await assertFailsAndDisconnects(client)
        let selects = await client.selectInboxCallCount
        XCTAssertEqual(selects, 0)
    }

    func testDisconnectsOnSelectFailure() async {
        let client = FakeIMAPClient()
        await client.setSelectInboxError(.selectFailed("Mailbox response missing UIDVALIDITY"))
        await assertFailsAndDisconnects(client)
    }

    private func assertFailsAndDisconnects(_ client: FakeIMAPClient, line: UInt = #line) async {
        do {
            try await AccountVerifier.verify(client: client, server: server, loginName: "x", password: "pw")
            XCTFail("Expected verification to fail", line: line)
        } catch {}
        let disconnects = await client.disconnectCallCount
        XCTAssertEqual(disconnects, 1, line: line)
    }

    func testTLSFailureOnCustomServerGetsAHintPresetsDoNot() {
        let tls = IMAPClientError.tlsHandshakeFailed(underlying: NSError(domain: "test", code: 1))
        XCTAssertTrue(AccountVerifier.message(for: tls, provider: .custom).contains("Check the server name and port."))
        XCTAssertFalse(AccountVerifier.message(for: tls, provider: .gmail).contains("Check the server name and port."))

        let auth = IMAPClientError.authenticationFailed
        XCTAssertEqual(AccountVerifier.message(for: auth, provider: .custom), auth.localizedDescription)
    }
}

final class CustomServerWorkerTests: XCTestCase {
    func testWorkerConnectsToTheCustomHostPortAndUsername() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = SyncStateStore(fileURL: tempDir.appendingPathComponent("sync_state.json"))
        let account = Account(
            email: "me@corp.example", provider: .custom,
            customServer: IMAPServer(host: "mail.corp.example", port: 1993), username: "jdoe"
        )
        let client = FakeIMAPClient()
        let worker = AccountSyncWorker(
            account: account,
            imapClient: client,
            manualCheckClientFactory: { client },
            syncStateStore: store,
            defaultSyncFrequency: .fiveMinutes,
            passwordProvider: { _ in "pw" },
            sleepProvider: { _ in try await Task.sleep(nanoseconds: 60_000_000_000) }
        )

        await worker.start()
        for _ in 0..<200 {
            if await client.loginCallCount >= 1 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        await worker.stop()

        let host = await client.lastConnectedHost
        let port = await client.lastConnectedPort
        let login = await client.lastLoginEmail
        XCTAssertEqual(host, "mail.corp.example")
        XCTAssertEqual(port, 1993)
        XCTAssertEqual(login, "jdoe")
    }

    func testManualCheckUsesTheCustomServerAndLoginName() async throws {
        let account = Account(
            email: "me@corp.example", provider: .custom,
            customServer: IMAPServer(host: "mail.corp.example", port: 1993), username: "jdoe"
        )
        let client = FakeIMAPClient()
        let worker = AccountSyncWorker(
            account: account,
            imapClient: FakeIMAPClient(),
            manualCheckClientFactory: { client },
            passwordProvider: { _ in "pw" }
        )

        _ = try await worker.checkUnreadCount()

        let host = await client.lastConnectedHost
        let login = await client.lastLoginEmail
        XCTAssertEqual(host, "mail.corp.example")
        XCTAssertEqual(login, "jdoe")
    }
}
