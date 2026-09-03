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

    /// The number of times `connect(host:port:)` has been called.
    public private(set) var connectCallCount: Int = 0

    /// The number of times `login(email:password:)` has been called.
    public private(set) var loginCallCount: Int = 0

    /// The number of times `disconnect()` has been called.
    public private(set) var disconnectCallCount: Int = 0

    /// The most recent host passed to `connect(host:port:)`.
    public private(set) var lastConnectedHost: String?

    /// The most recent port passed to `connect(host:port:)`.
    public private(set) var lastConnectedPort: Int?

    /// The most recent email passed to `login(email:password:)`.
    public private(set) var lastLoginEmail: String?

    /// The most recent password passed to `login(email:password:)`.
    public private(set) var lastLoginPassword: String?

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
    }

    /// Resets all recorded call counts and captured parameters.
    public func resetCallCounts() {
        connectCallCount = 0
        loginCallCount = 0
        disconnectCallCount = 0
        lastConnectedHost = nil
        lastConnectedPort = nil
        lastLoginEmail = nil
        lastLoginPassword = nil
    }
}
