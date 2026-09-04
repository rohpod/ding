import Foundation

/// In-memory test fake conforming to `IMAPConnecting`.
///
/// ## Purpose & Isolation
/// `FakeIMAPClient` simulates IMAP network and authentication operations in a completely hermetic,
/// in-memory environment. It allows unit tests and SwiftUI Previews to verify:
/// - Success and failure transitions during account addition or re-authentication flows.
/// - Correct handling and routing of typed errors (e.g., distinguishing `.authenticationFailed` from `.connectionFailed`).
/// - Clean disconnection and resource release without opening network sockets or calling live servers.
///
/// Under Swift 6 strict concurrency, `FakeIMAPClient` is implemented as an `actor` to guarantee thread-safe
/// mutable state without compiler warnings.
public actor FakeIMAPClient: IMAPConnecting {
    /// Pre-configured error thrown by `connect(host:port:)`. If `nil`, the connection succeeds.
    public var connectError: IMAPClientError?

    /// Pre-configured error thrown by `login(email:password:)`. If `nil`, authentication succeeds.
    public var loginError: IMAPClientError?

    /// Optional simulated latency duration before completing an operation.
    public var simulateLatency: Duration?

    /// Indicates whether the fake client is currently in a connected state.
    public private(set) var isConnected: Bool = false

    /// Pre-configured mailbox status returned by `selectInbox()`.
    public var mailboxStatus: MailboxStatus = MailboxStatus(uidValidity: 1, uidNext: 100, messageCount: 10, recentCount: 0)

    /// Pre-configured error thrown by `selectInbox()`. If `nil`, `mailboxStatus` is returned.
    public var selectInboxError: IMAPClientError?

    /// Pre-configured messages returned by `fetchNewMessages(sinceUID:)` (filtered by `uid > sinceUID`).
    public var cannedMessages: [MessageSummary] = []

    /// Pre-configured error thrown by `fetchNewMessages(sinceUID:)`.
    public var fetchMessagesError: IMAPClientError?

    /// Configurable server support for IMAP `IDLE`. Defaults to `true`.
    public var supportsIdleValue: Bool = true

    /// Pre-configured error thrown by `startIdle()`. If `nil`, IDLE stream begins.
    public var startIdleError: IMAPClientError?

    /// The number of times `connect(host:port:)` has been called.
    public private(set) var connectCallCount: Int = 0

    /// The number of times `login(email:password:)` has been called.
    public private(set) var loginCallCount: Int = 0

    /// The number of times `disconnect()` has been called.
    public private(set) var disconnectCallCount: Int = 0

    /// The number of times `selectInbox()` has been called.
    public private(set) var selectInboxCallCount: Int = 0

    /// The number of times `fetchNewMessages(sinceUID:)` has been called.
    public private(set) var fetchNewMessagesCallCount: Int = 0

    /// The number of times `startIdle()` has been called.
    public private(set) var startIdleCallCount: Int = 0

    /// The number of times `stopIdle()` has been called.
    public private(set) var stopIdleCallCount: Int = 0

    /// The number of times `supportsIdle()` has been called.
    public private(set) var supportsIdleCallCount: Int = 0

    /// The most recent host passed to `connect(host:port:)`.
    public private(set) var lastConnectedHost: String?

    /// The most recent port passed to `connect(host:port:)`.
    public private(set) var lastConnectedPort: Int?

    /// The most recent email passed to `login(email:password:)`.
    public private(set) var lastLoginEmail: String?

    /// The most recent password passed to `login(email:password:)`.
    public private(set) var lastLoginPassword: String?

    /// The most recent `sinceUID` passed to `fetchNewMessages(sinceUID:)`.
    public private(set) var lastFetchSinceUID: UInt32?

    private var idleContinuation: AsyncThrowingStream<IdleEvent, any Error>.Continuation?

    /// Initializes a new fake IMAP client.
    ///
    /// - Parameters:
    ///   - connectError: Optional error to simulate during `connect`.
    ///   - loginError: Optional error to simulate during `login`.
    ///   - simulateLatency: Optional artificial delay duration for async simulation.
    public init(
        connectError: IMAPClientError? = nil,
        loginError: IMAPClientError? = nil,
        simulateLatency: Duration? = nil
    ) {
        self.connectError = connectError
        self.loginError = loginError
        self.simulateLatency = simulateLatency
    }

    /// Sets the error to be thrown by future `connect(host:port:)` calls.
    public func setConnectError(_ error: IMAPClientError?) {
        self.connectError = error
    }

    /// Sets the error to be thrown by future `login(email:password:)` calls.
    public func setLoginError(_ error: IMAPClientError?) {
        self.loginError = error
    }

    /// Sets the mailbox status returned by future `selectInbox()` calls.
    public func setMailboxStatus(_ status: MailboxStatus) {
        self.mailboxStatus = status
    }

    /// Sets the error thrown by future `selectInbox()` calls.
    public func setSelectInboxError(_ error: IMAPClientError?) {
        self.selectInboxError = error
    }

    /// Sets the canned messages returned by future `fetchNewMessages(sinceUID:)` calls.
    public func setCannedMessages(_ messages: [MessageSummary]) {
        self.cannedMessages = messages
    }

    /// Sets the error thrown by future `fetchNewMessages(sinceUID:)` calls.
    public func setFetchMessagesError(_ error: IMAPClientError?) {
        self.fetchMessagesError = error
    }

    /// Sets whether the fake client reports supporting IMAP IDLE.
    public func setSupportsIdle(_ supports: Bool) {
        self.supportsIdleValue = supports
    }

    /// Sets the error thrown by future `startIdle()` calls.
    public func setStartIdleError(_ error: IMAPClientError?) {
        self.startIdleError = error
    }

    /// Simulates connecting to an IMAP server.
    public func connect(host: String, port: Int) async throws {
        connectCallCount += 1
        lastConnectedHost = host
        lastConnectedPort = port

        if let latency = simulateLatency {
            try await Task.sleep(for: latency)
        }

        if let error = connectError {
            isConnected = false
            throw error
        }

        isConnected = true
    }

    /// Simulates authenticating with an IMAP server.
    public func login(email: String, password: String) async throws {
        loginCallCount += 1
        lastLoginEmail = email
        lastLoginPassword = password

        guard isConnected else {
            throw IMAPClientError.notConnected
        }

        if let latency = simulateLatency {
            try await Task.sleep(for: latency)
        }

        if let error = loginError {
            throw error
        }
    }

    /// Simulates disconnecting from an IMAP server.
    public func disconnect() async {
        disconnectCallCount += 1
        isConnected = false
        idleContinuation?.finish()
        idleContinuation = nil
    }

    /// Simulates selecting the INBOX mailbox.
    public func selectInbox() async throws -> MailboxStatus {
        selectInboxCallCount += 1
        guard isConnected else {
            throw IMAPClientError.notConnected
        }
        if let error = selectInboxError {
            throw error
        }
        return mailboxStatus
    }

    /// Simulates fetching new messages arriving after `sinceUID`.
    public func fetchNewMessages(sinceUID: UInt32) async throws -> [MessageSummary] {
        fetchNewMessagesCallCount += 1
        lastFetchSinceUID = sinceUID
        guard isConnected else {
            throw IMAPClientError.notConnected
        }
        if let error = fetchMessagesError {
            throw error
        }
        return cannedMessages.filter { $0.uid > sinceUID }.sorted(by: { $0.uid < $1.uid })
    }

    /// Simulates starting an IDLE push notification stream.
    public func startIdle() async throws -> AsyncThrowingStream<IdleEvent, any Error> {
        startIdleCallCount += 1
        guard isConnected else {
            throw IMAPClientError.notConnected
        }
        guard supportsIdleValue else {
            throw IMAPClientError.idleNotSupported
        }
        if let error = startIdleError {
            throw error
        }

        return AsyncThrowingStream { continuation in
            self.idleContinuation = continuation
        }
    }

    /// Simulates terminating an active IDLE push stream.
    public func stopIdle() async throws {
        stopIdleCallCount += 1
        guard isConnected else {
            throw IMAPClientError.notConnected
        }
        idleContinuation?.finish()
        idleContinuation = nil
    }

    /// Simulates checking whether the server supports IDLE.
    public func supportsIdle() async throws -> Bool {
        supportsIdleCallCount += 1
        guard isConnected else {
            throw IMAPClientError.notConnected
        }
        return supportsIdleValue
    }

    /// Test helper to emit an `IdleEvent` into the currently active IDLE stream.
    public func yieldIdleEvent(_ event: IdleEvent) {
        idleContinuation?.yield(event)
    }

    /// Test helper to terminate the active IDLE stream with an error.
    public func failIdleStream(with error: any Error) {
        idleContinuation?.finish(throwing: error)
        idleContinuation = nil
    }

    /// Resets all recorded call counts and captured parameters.
    public func resetCallCounts() {
        connectCallCount = 0
        loginCallCount = 0
        disconnectCallCount = 0
        selectInboxCallCount = 0
        fetchNewMessagesCallCount = 0
        startIdleCallCount = 0
        stopIdleCallCount = 0
        supportsIdleCallCount = 0
        lastConnectedHost = nil
        lastConnectedPort = nil
        lastLoginEmail = nil
        lastLoginPassword = nil
        lastFetchSinceUID = nil
    }
}
