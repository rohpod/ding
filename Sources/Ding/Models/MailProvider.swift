import Foundation

/// Preset mail providers supported by ding.
///
/// ## Hardcoded Preset Decision (v1 Architecture)
/// In ding v1, mail providers are deliberately restricted to these 5 hardcoded presets:
/// Gmail, iCloud, Outlook, Yahoo, and Fastmail. Generic IMAP host/port/security configuration
/// is explicitly out of scope for v1 to maximize simplicity, reliability, and security.
///
/// Each preset encapsulates tested, known-good IMAP configuration parameters, domain mappings,
/// and direct links to provider security management portals where users can generate App Passwords.
public enum MailProvider: String, CaseIterable, Codable, Sendable {
    case gmail
    case icloud
    case outlook
    case yahoo
    case fastmail

    /// The user-facing display name of the mail provider.
    public var displayName: String {
        switch self {
        case .gmail:
            return "Gmail"
        case .icloud:
            return "iCloud"
        case .outlook:
            return "Outlook"
        case .yahoo:
            return "Yahoo"
        case .fastmail:
            return "Fastmail"
        }
    }

    /// The fully qualified domain name (FQDN) of the provider's IMAP server.
    public var imapHost: String {
        switch self {
        case .gmail:
            return "imap.gmail.com"
        case .icloud:
            return "imap.mail.me.com"
        case .outlook:
            return "outlook.office365.com"
        case .yahoo:
            return "imap.mail.yahoo.com"
        case .fastmail:
            return "imap.fastmail.com"
        }
    }

    /// The network port for IMAP over SSL/TLS.
    ///
    /// Port 993 is universally used for implicit TLS across all supported presets,
    /// but is kept explicit per-provider for future configuration flexibility.
    public var imapPort: Int {
        switch self {
        case .gmail, .icloud, .outlook, .yahoo, .fastmail:
            return 993
        }
    }

    /// Direct URL to the provider's account security portal where users can generate an App Password.
    public var appPasswordURL: URL {
        let urlString: String
        switch self {
        case .gmail:
            urlString = "https://myaccount.google.com/apppasswords"
        case .icloud:
            urlString = "https://appleid.apple.com/account/manage"
        case .outlook:
            urlString = "https://account.live.com/proofs/AppPassword"
        case .yahoo:
            urlString = "https://login.yahoo.com/myaccount/security"
        case .fastmail:
            urlString = "https://app.fastmail.com/settings/security/apppasswords"
        }
        // Force-unwrap justified: URLs are known static compile-time constants.
        return URL(string: urlString)!
    }

    /// Known email domain names associated with this provider.
    public var domains: [String] {
        switch self {
        case .gmail:
            return ["gmail.com", "googlemail.com"]
        case .icloud:
            return ["icloud.com", "me.com", "mac.com"]
        case .outlook:
            return ["outlook.com", "hotmail.com", "live.com", "msn.com"]
        case .yahoo:
            return ["yahoo.com", "ymail.com"]
        case .fastmail:
            return ["fastmail.com"]
        }
    }

    /// Detects the matching mail provider for a given email address based on its domain.
    ///
    /// - Parameter email: The candidate email address entered by the user.
    /// - Returns: The matched `MailProvider`, or `nil` if the domain does not match any known presets
    ///   or if the email format is invalid (indicating an unsupported provider in v1).
    public static func detect(fromEmail email: String) -> MailProvider? {
        let cleaned = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = cleaned.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            return nil
        }
        let domain = String(parts[1])

        return Self.allCases.first { provider in
            provider.domains.contains(domain)
        }
    }
}
