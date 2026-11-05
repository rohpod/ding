import Foundation

/// Mail providers supported by ding: five presets and a custom IMAP server.
///
/// ## Presets and the Custom Option
/// Each preset (Gmail, iCloud, Outlook, Yahoo, Fastmail) encapsulates a tested, known-good IMAP server, domain
/// mappings, and direct links to the provider's security portal where users can generate an App Password.
///
/// `.custom` covers everything else: Workspace and other custom domains, regional providers, self-hosted servers.
/// It has no preset server, so the server lives on the `Account` itself. Only implicit TLS with a trusted
/// certificate and password login are supported, which keeps the security story the same as for presets.
public enum MailProvider: String, CaseIterable, Codable, Sendable {
    case gmail
    case icloud
    case outlook
    case yahoo
    case fastmail
    case custom

    /// The providers with a built-in server, in picker order. Excludes `.custom`.
    public static var presets: [MailProvider] {
        allCases.filter { $0 != .custom }
    }

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
        case .custom:
            return "Other (IMAP)"
        }
    }

    /// The built-in IMAP server (implicit TLS on port 993), or `nil` for `.custom`, whose server is per account.
    public var presetServer: IMAPServer? {
        switch self {
        case .gmail:
            return IMAPServer(host: "imap.gmail.com", port: 993)
        case .icloud:
            return IMAPServer(host: "imap.mail.me.com", port: 993)
        case .outlook:
            return IMAPServer(host: "outlook.office365.com", port: 993)
        case .yahoo:
            return IMAPServer(host: "imap.mail.yahoo.com", port: 993)
        case .fastmail:
            return IMAPServer(host: "imap.fastmail.com", port: 993)
        case .custom:
            return nil
        }
    }

    /// Direct URL to the provider's account security portal where users can generate an App Password.
    /// `nil` for `.custom`, which has no known portal.
    public var appPasswordURL: URL? {
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
        case .custom:
            return nil
        }
        // Force-unwrap justified: URLs are known static compile-time constants.
        return URL(string: urlString)!
    }

    /// Direct URL to the provider's webmail in the default browser.
    ///
    /// Note: Deep-linking to the exact message varies by provider and is not implemented in v1;
    /// this opens the provider's general webmail portal without forcing specific user accounts or mailbox folders.
    /// `nil` for `.custom`, which has no known webmail.
    public var webmailURL: URL? {
        let urlString: String
        switch self {
        case .gmail:
            urlString = "https://mail.google.com"
        case .icloud:
            urlString = "https://www.icloud.com/mail"
        case .outlook:
            urlString = "https://outlook.live.com/mail"
        case .yahoo:
            urlString = "https://mail.yahoo.com"
        case .fastmail:
            urlString = "https://app.fastmail.com"
        case .custom:
            return nil
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
        case .custom:
            return []
        }
    }

    /// Detects the matching mail provider for a given email address based on its domain.
    ///
    /// - Parameter email: The candidate email address entered by the user.
    /// - Returns: The matched preset, or `nil` if the domain does not match any (the user then picks a provider
    ///   or enters a custom server) or if the email format is invalid.
    public static func detect(fromEmail email: String) -> MailProvider? {
        let cleaned = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = cleaned.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            return nil
        }
        let domain = String(parts[1])

        return Self.presets.first { provider in
            provider.domains.contains(domain)
        }
    }
}
