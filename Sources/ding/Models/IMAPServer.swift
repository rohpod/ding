import Foundation
import Network

/// An IMAP server reached over implicit TLS.
public struct IMAPServer: Codable, Equatable, Sendable {
    public let host: String
    public let port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    /// Why a user-entered server could not be accepted. The descriptions are shown inline in the Add Account sheet.
    public enum ValidationError: LocalizedError, Equatable, Sendable {
        case hostRequired
        case hostNotJustAName
        case hostNotASCII
        case hostIsIPAddress
        case portInvalid
        case portNeedsSTARTTLS

        public var errorDescription: String? {
            switch self {
            case .hostRequired:
                return "Enter the server name, e.g. mail.example.com."
            case .hostNotJustAName:
                return "Enter just the server name, e.g. mail.example.com."
            case .hostNotASCII:
                return "The server name can only contain letters, digits, dots and hyphens."
            case .hostIsIPAddress:
                return "Enter the server's name, not its IP address."
            case .portInvalid:
                return "Enter a port between 1 and 65535."
            case .portNeedsSTARTTLS:
                return "Port 143 needs STARTTLS, which ding doesn't support. Try 993."
            }
        }
    }

    /// Validates and normalizes a server typed by the user.
    ///
    /// The host is trimmed, lowercased and stripped of a trailing dot. IP addresses are rejected because the TLS
    /// layer cannot send one as the server name (SNI) and the resulting connection error would be confusing.
    /// IPv6 literals never get that far: they contain `:`.
    public static func validated(host rawHost: String, port rawPort: String) throws -> IMAPServer {
        var host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasSuffix(".") {
            host.removeLast()
        }

        guard !host.isEmpty else { throw ValidationError.hostRequired }
        guard !host.contains(where: { $0 == "/" || $0 == ":" || $0.isWhitespace }) else {
            throw ValidationError.hostNotJustAName
        }
        guard host.allSatisfy(\.isASCII) else { throw ValidationError.hostNotASCII }
        guard IPv4Address(host) == nil else { throw ValidationError.hostIsIPAddress }

        guard let port = Int(rawPort.trimmingCharacters(in: .whitespacesAndNewlines)), (1...65535).contains(port) else {
            throw ValidationError.portInvalid
        }
        guard port != 143 else { throw ValidationError.portNeedsSTARTTLS }

        return IMAPServer(host: host, port: port)
    }
}
