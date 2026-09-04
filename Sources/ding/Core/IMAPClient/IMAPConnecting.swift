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
/// Represents the mailbox state returned by an IMAP `SELECT` command.
public struct MailboxStatus: Sendable, Equatable {
    /// The unique identifier validity value for the mailbox.
    public let uidValidity: UInt32

    /// The predicted next unique identifier to be assigned to a new message.
    public let uidNext: UInt32

    /// The number of messages currently in the mailbox, if reported by the server.
    public let messageCount: UInt32?

    /// The number of messages with the `\Recent` flag set, if reported by the server.
    public let recentCount: UInt32?

    public init(
        uidValidity: UInt32,
        uidNext: UInt32,
        messageCount: UInt32? = nil,
        recentCount: UInt32? = nil
    ) {
        self.uidValidity = uidValidity
        self.uidNext = uidNext
        self.messageCount = messageCount
        self.recentCount = recentCount
    }
}

/// Lightweight metadata summary for an incoming email message (headers only, no body).
public struct MessageSummary: Identifiable, Sendable, Equatable {
    /// The IMAP message unique identifier (UID).
    public let uid: UInt32

    /// The message subject line.
    public let subject: String

    /// The formatted sender address or display name.
    public let from: String

    /// The timestamp when the message was received by the mail server or sent.
    public let dateReceived: Date

    public var id: UInt32 { uid }

    public init(
        uid: UInt32,
        subject: String,
        from: String,
        dateReceived: Date
    ) {
        self.uid = uid
        self.subject = subject
        self.from = from
        self.dateReceived = dateReceived
    }
}

/// Events emitted by an active IMAP `IDLE` stream.
public enum IdleEvent: Sendable, Equatable {
    /// Server notified of mailbox changes (e.g. `EXISTS`, `RECENT`, or `FETCH`), indicating new mail may be available.
    case newMailAvailable

    /// The IDLE session reached its inactivity refresh threshold.
    case idleTimedOut
}

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

    /// Issues an IMAP `SELECT INBOX` command to select the primary inbox and retrieve its mailbox status.
    ///
    /// - Returns: A `MailboxStatus` containing `uidValidity`, `uidNext`, and message counts.
    /// - Throws: `IMAPClientError.notConnected`, `IMAPClientError.selectFailed`, or other `IMAPClientError`s.
    func selectInbox() async throws -> MailboxStatus

    /// Fetches lightweight header summaries for messages with a UID greater than `sinceUID`.
    ///
    /// - Parameter sinceUID: The highest UID previously processed. Only messages with `uid > sinceUID` are fetched.
    /// - Returns: An array of `MessageSummary` structs sorted ascending by UID.
    /// - Throws: `IMAPClientError.notConnected`, `IMAPClientError.timeout`, or network errors.
    func fetchNewMessages(sinceUID: UInt32) async throws -> [MessageSummary]

    /// Starts an IMAP `IDLE` session and returns an asynchronous stream of untagged server events.
    ///
    /// - Returns: An `AsyncThrowingStream` emitting `IdleEvent`s.
    /// - Throws: `IMAPClientError.notConnected`, `IMAPClientError.idleNotSupported`, or network errors.
    func startIdle() async throws -> AsyncThrowingStream<IdleEvent, any Error>

    /// Cleanly terminates an active IMAP `IDLE` session by sending the `DONE` continuation token.
    ///
    /// - Throws: `IMAPClientError.notConnected`, `IMAPClientError.timeout`, or network errors.
    func stopIdle() async throws

    /// Queries the server capabilities to determine if the `IDLE` extension (RFC 2177) is supported.
    ///
    /// - Returns: `true` if `IDLE` is advertised in the server's capabilities; `false` otherwise.
    /// - Throws: `IMAPClientError.notConnected` or network errors.
    func supportsIdle() async throws -> Bool
}
