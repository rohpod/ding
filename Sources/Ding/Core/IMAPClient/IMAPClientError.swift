import Foundation

/// Errors that can occur during IMAP connection, TLS negotiation, and authentication.
///
/// ## Error Architecture & UX Differentiation
/// A central requirement of Ding's account management is distinguishing authentication failures
/// (`.authenticationFailed`) from network/connectivity failures (`.connectionFailed`, `.timeout`,
/// `.tlsHandshakeFailed`).
///
/// In the user interface:
/// - **`.authenticationFailed`**: Indicates that the server explicitly rejected the credentials
///   (e.g., via an IMAP `NO` or `BAD` response). The user must be instructed that their App Password
///   is incorrect, expired, or revoked, prompting them to generate and enter a fresh one.
/// - **`.connectionFailed` / `.timeout`**: Indicates the server could not be reached (offline, DNS failure,
///   or connection refused). The user should be informed that the network is unavailable without alarming
///   them that their credentials are bad.
/// - **`.tlsHandshakeFailed`**: Indicates a security failure during TLS negotiation (e.g., certificate
///   validation or host mismatch).
public enum IMAPClientError: LocalizedError, Sendable, Equatable {
    /// The TCP or transport-level network connection could not be established or was dropped unexpectedly.
    case connectionFailed(underlying: any Error & Sendable)

    /// The TLS/SSL handshake negotiation failed or certificate validation was rejected.
    case tlsHandshakeFailed(underlying: any Error & Sendable)

    /// The server rejected the username or app password during IMAP `LOGIN`.
    case authenticationFailed

    /// The server returned an unexpected, malformed, or unparseable response.
    case unexpectedResponse(String)

    /// The connection or command operation exceeded the timeout duration without completing.
    case timeout

    /// An operation requiring an active connection (such as `login`) was called while disconnected.
    case notConnected

    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let underlying):
            return "Failed to connect to the mail server: \(underlying.localizedDescription)"
        case .tlsHandshakeFailed(let underlying):
            return "Secure TLS connection could not be established: \(underlying.localizedDescription)"
        case .authenticationFailed:
            return "Authentication failed. The email address or App Password is incorrect or has been revoked."
        case .unexpectedResponse(let details):
            return "Received an unexpected response from the mail server: \(details)"
        case .timeout:
            return "The operation timed out while waiting for a response from the mail server."
        case .notConnected:
            return "The mail client is not connected to any server."
        }
    }

    public static func == (lhs: IMAPClientError, rhs: IMAPClientError) -> Bool {
        switch (lhs, rhs) {
        case (.authenticationFailed, .authenticationFailed),
             (.timeout, .timeout),
             (.notConnected, .notConnected):
            return true

        case (.unexpectedResponse(let lhsDetails), .unexpectedResponse(let rhsDetails)):
            return lhsDetails == rhsDetails

        case (.connectionFailed(let lhsError), .connectionFailed(let rhsError)):
            if (lhsError as NSError) == (rhsError as NSError) {
                return true
            }
            return String(describing: lhsError) == String(describing: rhsError)

        case (.tlsHandshakeFailed(let lhsError), .tlsHandshakeFailed(let rhsError)):
            if (lhsError as NSError) == (rhsError as NSError) {
                return true
            }
            return String(describing: lhsError) == String(describing: rhsError)

        default:
            return false
        }
    }
}
