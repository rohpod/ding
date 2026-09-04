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

        let idleErr = IMAPClientError.idleNotSupported
        let selectErr1 = IMAPClientError.selectFailed("Mailbox does not exist")
        let selectErr2 = IMAPClientError.selectFailed("Mailbox does not exist")
        let selectErr3 = IMAPClientError.selectFailed("Permission denied")

        // Same-case equality
        XCTAssertEqual(authErr, .authenticationFailed)
        XCTAssertEqual(timeoutErr, .timeout)
        XCTAssertEqual(notConnErr, .notConnected)
        XCTAssertEqual(unexpErr1, unexpErr2)
        XCTAssertEqual(connErr1, connErr2)
        XCTAssertEqual(tlsErr1, tlsErr2)
        XCTAssertEqual(idleErr, .idleNotSupported)
        XCTAssertEqual(selectErr1, selectErr2)

        // Same-case inequality with different payloads
        XCTAssertNotEqual(unexpErr1, unexpErr3)
        XCTAssertNotEqual(connErr1, connErr3)
        XCTAssertNotEqual(tlsErr1, tlsErr3)
        XCTAssertNotEqual(selectErr1, selectErr3)

        // Cross-case inequality (crucial for UX path separation)
        XCTAssertNotEqual(authErr, connErr1)
        XCTAssertNotEqual(authErr, tlsErr1)
        XCTAssertNotEqual(authErr, timeoutErr)
        XCTAssertNotEqual(authErr, notConnErr)
        XCTAssertNotEqual(authErr, idleErr)
        XCTAssertNotEqual(authErr, selectErr1)
        XCTAssertNotEqual(connErr1, tlsErr1)
        XCTAssertNotEqual(connErr1, timeoutErr)
        XCTAssertNotEqual(tlsErr1, timeoutErr)
        XCTAssertNotEqual(idleErr, selectErr1)
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

        let idleErr = IMAPClientError.idleNotSupported
        XCTAssertNotNil(idleErr.errorDescription)
        XCTAssertTrue(idleErr.errorDescription!.contains("IDLE"))

        let selectErr = IMAPClientError.selectFailed("Mailbox locked")
        XCTAssertNotNil(selectErr.errorDescription)
        XCTAssertTrue(selectErr.errorDescription!.contains("Mailbox locked"))
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
        _ = try await client.selectInbox()
        _ = try await client.fetchNewMessages(sinceUID: 0)
        _ = try await client.supportsIdle()
        _ = try await client.startIdle()
        try await client.stopIdle()
        await client.disconnect()

        await client.resetCallCounts()

        let connectCount = await client.connectCallCount
        let loginCount = await client.loginCallCount
        let disconnectCount = await client.disconnectCallCount
        let selectCount = await client.selectInboxCallCount
        let fetchCount = await client.fetchNewMessagesCallCount
        let startIdleCount = await client.startIdleCallCount
        let stopIdleCount = await client.stopIdleCallCount
        let supportsIdleCount = await client.supportsIdleCallCount
        let lastHost = await client.lastConnectedHost
        let lastSinceUID = await client.lastFetchSinceUID

        XCTAssertEqual(connectCount, 0)
        XCTAssertEqual(loginCount, 0)
        XCTAssertEqual(disconnectCount, 0)
        XCTAssertEqual(selectCount, 0)
        XCTAssertEqual(fetchCount, 0)
        XCTAssertEqual(startIdleCount, 0)
        XCTAssertEqual(stopIdleCount, 0)
        XCTAssertEqual(supportsIdleCount, 0)
        XCTAssertNil(lastHost)
        XCTAssertNil(lastSinceUID)
    }

    func testFakeIMAPClientSelectInbox() async throws {
        let client = FakeIMAPClient()

        // 1. Throws notConnected when disconnected
        do {
            _ = try await client.selectInbox()
            XCTFail("Expected selectInbox to throw .notConnected")
        } catch let error as IMAPClientError {
            XCTAssertEqual(error, .notConnected)
        }

        // 2. Connected returns default mailbox status
        try await client.connect(host: "imap.example.com", port: 993)
        try await client.login(email: "user@example.com", password: "pwd")
        let status = try await client.selectInbox()
        XCTAssertEqual(status.uidValidity, 1)
        XCTAssertEqual(status.uidNext, 100)
        let selectCount = await client.selectInboxCallCount
        XCTAssertEqual(selectCount, 2)

        // 3. Simulates select failure
        await client.setSelectInboxError(.selectFailed("Mailbox locked"))
        do {
            _ = try await client.selectInbox()
            XCTFail("Expected selectInbox to fail")
        } catch let error as IMAPClientError {
            XCTAssertEqual(error, .selectFailed("Mailbox locked"))
        }
        let finalCount = await client.selectInboxCallCount
        XCTAssertEqual(finalCount, 3)
    }

    func testFakeIMAPClientFetchNewMessages() async throws {
        let client = FakeIMAPClient()

        // 1. Throws notConnected when disconnected
        do {
            _ = try await client.fetchNewMessages(sinceUID: 10)
            XCTFail("Expected fetchNewMessages to throw .notConnected")
        } catch let error as IMAPClientError {
            XCTAssertEqual(error, .notConnected)
        }

        try await client.connect(host: "imap.example.com", port: 993)
        try await client.login(email: "user@example.com", password: "pwd")

        // 2. Configure canned messages and test filtering
        let msg1 = MessageSummary(uid: 10, subject: "Old", from: "a@b.com", dateReceived: Date())
        let msg2 = MessageSummary(uid: 20, subject: "New 1", from: "c@d.com", dateReceived: Date())
        let msg3 = MessageSummary(uid: 30, subject: "New 2", from: "e@f.com", dateReceived: Date())
        await client.setCannedMessages([msg3, msg1, msg2])

        let fetched = try await client.fetchNewMessages(sinceUID: 15)
        XCTAssertEqual(fetched.count, 2)
        XCTAssertEqual(fetched[0].uid, 20)
        XCTAssertEqual(fetched[1].uid, 30)

        let lastSince = await client.lastFetchSinceUID
        XCTAssertEqual(lastSince, 15)

        // 3. Simulates fetch error
        await client.setFetchMessagesError(.unexpectedResponse("Fetch failed"))
        do {
            _ = try await client.fetchNewMessages(sinceUID: 15)
            XCTFail("Expected fetch to fail")
        } catch let error as IMAPClientError {
            XCTAssertEqual(error, .unexpectedResponse("Fetch failed"))
        }
    }

    func testFakeIMAPClientSupportsIdleAndStartStopIdle() async throws {
        let client = FakeIMAPClient()

        // 1. Throws notConnected when disconnected
        do {
            _ = try await client.supportsIdle()
            XCTFail("Expected supportsIdle to throw .notConnected")
        } catch let error as IMAPClientError {
            XCTAssertEqual(error, .notConnected)
        }

        try await client.connect(host: "imap.example.com", port: 993)
        try await client.login(email: "user@example.com", password: "pwd")

        // 2. Supports IDLE returns true by default
        let supports = try await client.supportsIdle()
        XCTAssertTrue(supports)

        // 3. Start idle and yield event
        let idleStream = try await client.startIdle()
        let startCount = await client.startIdleCallCount
        XCTAssertEqual(startCount, 1)

        Task {
            await client.yieldIdleEvent(.newMailAvailable)
        }

        var receivedEvent: IdleEvent?
        for try await event in idleStream {
            receivedEvent = event
            break
        }
        XCTAssertEqual(receivedEvent, .newMailAvailable)

        // 4. Stop idle
        try await client.stopIdle()
        let stopCount = await client.stopIdleCallCount
        XCTAssertEqual(stopCount, 1)

        // 5. When IDLE is not supported, startIdle throws idleNotSupported
        await client.setSupportsIdle(false)
        do {
            _ = try await client.startIdle()
            XCTFail("Expected startIdle to throw .idleNotSupported")
        } catch let error as IMAPClientError {
            XCTAssertEqual(error, .idleNotSupported)
        }
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
