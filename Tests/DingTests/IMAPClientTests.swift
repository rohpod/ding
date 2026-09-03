import XCTest
@testable import ding

final class IMAPClientTests: XCTestCase {

    // MARK: - IMAPClientError Tests

    func testIMAPClientErrorDistinguishabilityAndEquality() {
        let authErr = IMAPClientError.authenticationFailed
        let timeoutErr = IMAPClientError.timeout
        let notConnErr = IMAPClientError.notConnected
        let unexpErr1 = IMAPClientError.unexpectedResponse("BAD syntax")
        let unexpErr2 = IMAPClientError.unexpectedResponse("BAD syntax")
        let unexpErr3 = IMAPClientError.unexpectedResponse("OTHER")

        let nsErr1 = NSError(domain: "net.ding.test", code: 500, userInfo: [NSLocalizedDescriptionKey: "Conn reset"])
        let nsErr2 = NSError(domain: "net.ding.test", code: 500, userInfo: [NSLocalizedDescriptionKey: "Conn reset"])
        let nsErr3 = NSError(domain: "net.ding.test", code: 501, userInfo: [NSLocalizedDescriptionKey: "Unreachable"])

        let connErr1 = IMAPClientError.connectionFailed(underlying: nsErr1)
        let connErr2 = IMAPClientError.connectionFailed(underlying: nsErr2)
        let connErr3 = IMAPClientError.connectionFailed(underlying: nsErr3)

        let tlsErr1 = IMAPClientError.tlsHandshakeFailed(underlying: nsErr1)
        let tlsErr2 = IMAPClientError.tlsHandshakeFailed(underlying: nsErr2)
        let tlsErr3 = IMAPClientError.tlsHandshakeFailed(underlying: nsErr3)

        // Same-case equality
        XCTAssertEqual(authErr, .authenticationFailed)
        XCTAssertEqual(timeoutErr, .timeout)
        XCTAssertEqual(notConnErr, .notConnected)
        XCTAssertEqual(unexpErr1, unexpErr2)
        XCTAssertEqual(connErr1, connErr2)
        XCTAssertEqual(tlsErr1, tlsErr2)

        // Same-case inequality with different payloads
        XCTAssertNotEqual(unexpErr1, unexpErr3)
        XCTAssertNotEqual(connErr1, connErr3)
        XCTAssertNotEqual(tlsErr1, tlsErr3)

        // Cross-case inequality (crucial for UX path separation)
        XCTAssertNotEqual(authErr, connErr1)
        XCTAssertNotEqual(authErr, tlsErr1)
        XCTAssertNotEqual(authErr, timeoutErr)
        XCTAssertNotEqual(authErr, notConnErr)
        XCTAssertNotEqual(connErr1, tlsErr1)
        XCTAssertNotEqual(connErr1, timeoutErr)
        XCTAssertNotEqual(tlsErr1, timeoutErr)
    }

    func testIMAPClientErrorDescriptions() {
        let authErr = IMAPClientError.authenticationFailed
        XCTAssertNotNil(authErr.errorDescription)
        XCTAssertTrue(authErr.errorDescription!.contains("Authentication failed"))
        XCTAssertTrue(authErr.errorDescription!.contains("App Password"))

        let testUnderlying = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Host unreachable"])
        let connErr = IMAPClientError.connectionFailed(underlying: testUnderlying)
        XCTAssertNotNil(connErr.errorDescription)
        XCTAssertTrue(connErr.errorDescription!.contains("Host unreachable"))

        let tlsErr = IMAPClientError.tlsHandshakeFailed(underlying: testUnderlying)
        XCTAssertNotNil(tlsErr.errorDescription)
        XCTAssertTrue(tlsErr.errorDescription!.contains("TLS"))

        let timeoutErr = IMAPClientError.timeout
        XCTAssertNotNil(timeoutErr.errorDescription)
        XCTAssertTrue(timeoutErr.errorDescription!.contains("timed out"))

        let notConnErr = IMAPClientError.notConnected
        XCTAssertNotNil(notConnErr.errorDescription)
        XCTAssertTrue(notConnErr.errorDescription!.contains("not connected"))

        let unexpErr = IMAPClientError.unexpectedResponse("UNKNOWN 42")
        XCTAssertNotNil(unexpErr.errorDescription)
        XCTAssertTrue(unexpErr.errorDescription!.contains("UNKNOWN 42"))
    }

    // MARK: - FakeIMAPClient Tests

    func testFakeIMAPClientInitialState() async {
        let client = FakeIMAPClient()

        let isConnected = await client.isConnected
        let connectCount = await client.connectCallCount
        let loginCount = await client.loginCallCount
        let disconnectCount = await client.disconnectCallCount

        XCTAssertFalse(isConnected)
        XCTAssertEqual(connectCount, 0)
        XCTAssertEqual(loginCount, 0)
        XCTAssertEqual(disconnectCount, 0)
    }

    func testFakeIMAPClientSuccessfulLifecycle() async throws {
        let client = FakeIMAPClient()

        // 1. Connect
        try await client.connect(host: "imap.gmail.com", port: 993)

        let isConnectedAfterConnect = await client.isConnected
        let connectCount = await client.connectCallCount
        let lastHost = await client.lastConnectedHost
        let lastPort = await client.lastConnectedPort

        XCTAssertTrue(isConnectedAfterConnect)
        XCTAssertEqual(connectCount, 1)
        XCTAssertEqual(lastHost, "imap.gmail.com")
        XCTAssertEqual(lastPort, 993)

        // 2. Login
        try await client.login(email: "user@gmail.com", password: "app-password-1234")

        let loginCount = await client.loginCallCount
        let lastEmail = await client.lastLoginEmail
        let lastPassword = await client.lastLoginPassword

        XCTAssertEqual(loginCount, 1)
        XCTAssertEqual(lastEmail, "user@gmail.com")
        XCTAssertEqual(lastPassword, "app-password-1234")

        // 3. Disconnect
        await client.disconnect()

        let isConnectedAfterDisconnect = await client.isConnected
        let disconnectCount = await client.disconnectCallCount

        XCTAssertFalse(isConnectedAfterDisconnect)
        XCTAssertEqual(disconnectCount, 1)
    }

    func testFakeIMAPClientLoginWithoutConnectThrowsNotConnected() async {
        let client = FakeIMAPClient()

        do {
            try await client.login(email: "user@fastmail.com", password: "pwd")
            XCTFail("Expected login without connect to throw .notConnected")
        } catch let error as IMAPClientError {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testFakeIMAPClientSimulatesConnectionFailure() async {
        let underlying = NSError(domain: "test", code: -1004, userInfo: [NSLocalizedDescriptionKey: "Connection refused"])
        let client = FakeIMAPClient(connectError: .connectionFailed(underlying: underlying))

        do {
            try await client.connect(host: "imap.fastmail.com", port: 993)
            XCTFail("Expected connect to fail")
        } catch let error as IMAPClientError {
            XCTAssertEqual(error, .connectionFailed(underlying: underlying))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let isConnected = await client.isConnected
        XCTAssertFalse(isConnected)
    }

    func testFakeIMAPClientSimulatesTLSHandshakeFailure() async {
        let underlying = NSError(domain: "tls", code: -9800)
        let client = FakeIMAPClient(connectError: .tlsHandshakeFailed(underlying: underlying))

        do {
            try await client.connect(host: "imap.mail.yahoo.com", port: 993)
            XCTFail("Expected connect to fail with TLS error")
        } catch let error as IMAPClientError {
            XCTAssertEqual(error, .tlsHandshakeFailed(underlying: underlying))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let isConnected = await client.isConnected
        XCTAssertFalse(isConnected)
    }

    func testFakeIMAPClientSimulatesAuthenticationFailure() async throws {
        let client = FakeIMAPClient(loginError: .authenticationFailed)

        try await client.connect(host: "imap.mail.me.com", port: 993)
        let isConnected = await client.isConnected
        XCTAssertTrue(isConnected)

        do {
            try await client.login(email: "user@icloud.com", password: "wrong-app-password")
            XCTFail("Expected login to fail with authenticationFailed")
        } catch let error as IMAPClientError {
            XCTAssertEqual(error, .authenticationFailed)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFakeIMAPClientSimulatesTimeout() async throws {
        let client = FakeIMAPClient(loginError: .timeout)

        try await client.connect(host: "outlook.office365.com", port: 993)

        do {
            try await client.login(email: "user@outlook.com", password: "pwd")
            XCTFail("Expected timeout error")
        } catch let error as IMAPClientError {
            XCTAssertEqual(error, .timeout)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFakeIMAPClientDynamicReconfiguration() async throws {
        let client = FakeIMAPClient()

        try await client.connect(host: "imap.gmail.com", port: 993)

        // First attempt: simulate wrong password
        await client.setLoginError(.authenticationFailed)
        do {
            try await client.login(email: "user@gmail.com", password: "old-password")
            XCTFail("Expected failure")
        } catch let error as IMAPClientError {
            XCTAssertEqual(error, .authenticationFailed)
        }

        // Second attempt: user corrects password, simulate success
        await client.setLoginError(nil)
        try await client.login(email: "user@gmail.com", password: "corrected-password")

        let lastPassword = await client.lastLoginPassword
        XCTAssertEqual(lastPassword, "corrected-password")
    }

    func testFakeIMAPClientResetCallCounts() async throws {
        let client = FakeIMAPClient()

        try await client.connect(host: "imap.gmail.com", port: 993)
        try await client.login(email: "a@b.com", password: "p")
        await client.disconnect()

        await client.resetCallCounts()

        let connectCount = await client.connectCallCount
        let loginCount = await client.loginCallCount
        let disconnectCount = await client.disconnectCallCount
        let lastHost = await client.lastConnectedHost

        XCTAssertEqual(connectCount, 0)
        XCTAssertEqual(loginCount, 0)
        XCTAssertEqual(disconnectCount, 0)
        XCTAssertNil(lastHost)
    }

    // MARK: - NIOIMAPClient Hermetic Offline Preconditions Tests

    func testNIOIMAPClientInitialStateAndLoginPrecondition() async {
        let client = NIOIMAPClient()

        let isConnected = await client.isConnected
        XCTAssertFalse(isConnected, "NIOIMAPClient should initially be disconnected")

        do {
            try await client.login(email: "test@example.com", password: "password")
            XCTFail("Expected calling login prior to connect to throw .notConnected")
        } catch let error as IMAPClientError {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // Disconnecting while already disconnected should be safe and idempotent
        await client.disconnect()
        let isConnectedAfterDisconnect = await client.isConnected
        XCTAssertFalse(isConnectedAfterDisconnect)
    }
}
