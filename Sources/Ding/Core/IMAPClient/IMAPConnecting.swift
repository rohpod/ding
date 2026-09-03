import Foundation

/// Protocol defining the contract for IMAP connection and authentication operations.
///
/// ## Architecture & Testability Seam
/// `IMAPConnecting` serves as the primary abstraction boundary between higher-level application components
/// (such as `AccountManager`, the "Add Account" verification flow, and the future `SyncEngine`) and the
/// underlying networking engine.
///
/// By depending on `IMAPConnecting` rather than concrete SwiftNIO networking types:
/// - **Hermetic Unit Testing**: Tests can substitute an in-memory test double (`FakeIMAPClient`) that simulates
///   various network and authentication outcomes without opening sockets or hitting live mail servers in CI.
/// - **SwiftUI Previews**: Interactive account configuration previews can simulate immediate connection success
///   or typed failure scenarios.
/// - **Actor Concurrency Boundary**: Because live IMAP networking involves complex, mutable connection and channel
///   state, real implementations (such as `NIOIMAPClient`) are implemented as Swift `actor`s. This protocol's
///   asynchronous contract accommodates actor isolation cleanly under Swift 6 strict concurrency rules.
public protocol IMAPConnecting: Sendable {
    /// Indicates whether the client currently maintains an active network connection to the IMAP server.
    var isConnected: Bool { get async }

    /// Establishes a TLS-encrypted IMAP connection to the specified server host and port.
    ///
    /// - Parameters:
    ///   - host: The fully qualified domain name (FQDN) or IP address of the IMAP server (e.g., `"imap.gmail.com"`).
    ///   - port: The network port (typically `993` for implicit TLS).
    /// - Throws: `IMAPClientError.tlsHandshakeFailed` if TLS negotiation fails,
    ///   `IMAPClientError.connectionFailed` on network or socket errors,
    ///   or `IMAPClientError.timeout` if the connection attempt exceeds the timeout window.
    func connect(host: String, port: Int) async throws

    /// Authenticates with the connected IMAP server using the provided credentials via IMAP `LOGIN`.
    ///
    /// - Parameters:
    ///   - email: The account username/email address.
    ///   - password: The IMAP app password.
    /// - Throws: `IMAPClientError.notConnected` if called prior to `connect(host:port:)`,
    ///   `IMAPClientError.authenticationFailed` if the server returns a `NO` or `BAD` response to credentials,
    ///   `IMAPClientError.unexpectedResponse` if the server returns an unrecognized response,
    ///   or `IMAPClientError.timeout` if the command times out.
    func login(email: String, password: String) async throws

    /// Cleanly closes the IMAP session (issuing a `LOGOUT` command if connected) and releases connection resources.
    func disconnect() async
}
