import Foundation

/// Represents a configured user mail account in ding.
///
/// ## Security Architecture & Secret Separation
/// This struct intentionally does **NOT** contain the user's password, App Password, or token.
///
/// Authentication secrets live exclusively in the macOS system Keychain (`KeychainService`),
/// keyed by the account's unique `id` (`UUID`). This strict separation ensures that sensitive credentials
/// are never serialized to disk, written into plaintext JSON files (`accounts.json`), or exposed in memory dumps
/// during standard model encoding/decoding workflows.
public struct Account: Identifiable, Codable, Equatable, Sendable {
    /// Unique and immutable identifier for this account across app sessions and storage.
    public let id: UUID

    /// The user's full email address for this account.
    public var email: String

    /// The mail provider (a preset or `.custom`) governing connection and authentication endpoints.
    public var provider: MailProvider

    /// An optional user-specified nickname for this account (e.g., "Work" or "Personal").
    public var alias: String?

    /// The polling frequency or push synchronization mode for this account.
    ///
    /// Defaults to `.useDefault`, which resolves to `AppPreferences.shared.defaultSyncFrequency`.
    public var syncFrequency: SyncFrequency

    /// The action triggered when a notification from this account is clicked.
    ///
    /// Defaults to `.useDefault`, which resolves to `AppPreferences.shared.defaultNotificationClickBehavior`.
    public var notificationClickBehavior: NotificationClickBehavior

    /// Flag indicating whether the account's credentials have been rejected by the mail server
    /// and require user re-authentication.
    ///
    /// Defaults to `false`. The `SyncEngine` sets this flag to `true` when it detects
    /// authentication failures (such as revoked app passwords or expired credentials) during sync.
    public var needsReauthentication: Bool

    /// Flag indicating whether the account is included when performing a global manual "Check for Mail" operation.
    ///
    /// Defaults to `true`.
    public var includeInManualCheck: Bool

    /// The user's own IMAP server, set only for `.custom` accounts. Presets use `MailProvider.presetServer`.
    public var customServer: IMAPServer?

    /// The login name when it differs from `email`, as some servers expect a bare username. `nil` means the email.
    public var username: String?

    /// Timestamp when this account was added to ding.
    public let dateAdded: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case email
        case provider
        case alias
        case syncFrequency
        case notificationClickBehavior
        case needsReauthentication
        case includeInManualCheck
        case customServer
        case username
        case dateAdded
    }

    /// Initializes a new mail account model.
    ///
    /// - Parameters:
    ///   - id: The stable account identifier. Defaults to a newly generated `UUID`.
    ///   - email: The account email address.
    ///   - provider: The mail provider, a preset or `.custom`.
    ///   - alias: An optional display alias/nickname.
    ///   - syncFrequency: The synchronization frequency. Defaults to `.useDefault`.
    ///   - notificationClickBehavior: The notification click behavior. Defaults to `.useDefault`.
    ///   - needsReauthentication: Flag indicating if the account requires re-authentication. Defaults to `false`.
    ///   - includeInManualCheck: Flag indicating if the account is included in manual mail check. Defaults to `true`.
    ///   - dateAdded: The timestamp when the account was created. Defaults to the current date.
    ///   - customServer: The IMAP server for a `.custom` provider. Defaults to `nil`.
    ///   - username: The login name when it differs from the email. Defaults to `nil`.
    public init(
        id: UUID = UUID(),
        email: String,
        provider: MailProvider,
        alias: String? = nil,
        syncFrequency: SyncFrequency = .useDefault,
        notificationClickBehavior: NotificationClickBehavior = .useDefault,
        needsReauthentication: Bool = false,
        includeInManualCheck: Bool = true,
        dateAdded: Date = Date(),
        customServer: IMAPServer? = nil,
        username: String? = nil
    ) {
        self.id = id
        self.email = email
        self.provider = provider
        self.alias = alias
        self.syncFrequency = syncFrequency
        self.notificationClickBehavior = notificationClickBehavior
        self.needsReauthentication = needsReauthentication
        self.includeInManualCheck = includeInManualCheck
        self.customServer = customServer
        self.username = username
        // Floor to whole seconds so date equality survives ISO-8601 serialization without fractional discrepancies
        // and never rounds into the future.
        self.dateAdded = Date(timeIntervalSince1970: floor(dateAdded.timeIntervalSince1970))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.email = try container.decode(String.self, forKey: .email)
        self.provider = try container.decode(MailProvider.self, forKey: .provider)
        self.alias = try container.decodeIfPresent(String.self, forKey: .alias)
        self.syncFrequency = try container.decodeIfPresent(SyncFrequency.self, forKey: .syncFrequency) ?? .useDefault
        self.notificationClickBehavior = try container.decodeIfPresent(NotificationClickBehavior.self, forKey: .notificationClickBehavior) ?? .useDefault
        self.needsReauthentication = try container.decodeIfPresent(Bool.self, forKey: .needsReauthentication) ?? false
        self.includeInManualCheck = try container.decodeIfPresent(Bool.self, forKey: .includeInManualCheck) ?? true
        self.customServer = try container.decodeIfPresent(IMAPServer.self, forKey: .customServer)
        self.username = try container.decodeIfPresent(String.self, forKey: .username)
        self.dateAdded = try container.decode(Date.self, forKey: .dateAdded)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(email, forKey: .email)
        try container.encode(provider, forKey: .provider)
        try container.encodeIfPresent(alias, forKey: .alias)
        try container.encode(syncFrequency, forKey: .syncFrequency)
        try container.encode(notificationClickBehavior, forKey: .notificationClickBehavior)
        try container.encode(needsReauthentication, forKey: .needsReauthentication)
        try container.encode(includeInManualCheck, forKey: .includeInManualCheck)
        try container.encodeIfPresent(customServer, forKey: .customServer)
        try container.encodeIfPresent(username, forKey: .username)
        try container.encode(dateAdded, forKey: .dateAdded)
    }

    /// Normalizes an optional account alias by trimming whitespace and newlines, returning `nil` if empty.
    public static func normalizeAlias(_ alias: String?) -> String? {
        guard let trimmed = alias?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// The server to connect to: the account's own for `.custom`, otherwise the provider's preset.
    ///
    /// The empty fallback is reachable only from a hand-edited file. It fails at connect and shows up in the
    /// account's health, which is better than failing the whole decode and quarantining every account.
    public var server: IMAPServer {
        customServer ?? provider.presetServer ?? IMAPServer(host: "", port: 993)
    }

    /// The name sent to `LOGIN`: the explicit `username`, or the email address.
    public var loginName: String {
        username ?? email
    }

    /// What the user calls their secret: custom servers take an ordinary password, presets an app password.
    public var credentialName: String {
        provider == .custom ? "password" : "app password"
    }

    /// Normalizes a login name by trimming whitespace, returning `nil` when it is empty or just the email again.
    public static func normalizeUsername(_ username: String?, email: String) -> String? {
        guard let trimmed = username?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
              trimmed.caseInsensitiveCompare(email.trimmingCharacters(in: .whitespacesAndNewlines)) != .orderedSame else {
            return nil
        }
        return trimmed
    }

    /// User-facing display name for UI presentation.
    ///
    /// Returns the normalized `alias` if present, otherwise falls back to `email`.
    public var displayName: String {
        if let alias = Self.normalizeAlias(alias) {
            return alias
        }
        return email
    }

    public static func == (lhs: Account, rhs: Account) -> Bool {
        lhs.id == rhs.id &&
        lhs.email == rhs.email &&
        lhs.provider == rhs.provider &&
        lhs.alias == rhs.alias &&
        lhs.syncFrequency == rhs.syncFrequency &&
        lhs.notificationClickBehavior == rhs.notificationClickBehavior &&
        lhs.needsReauthentication == rhs.needsReauthentication &&
        lhs.includeInManualCheck == rhs.includeInManualCheck &&
        lhs.customServer == rhs.customServer &&
        lhs.username == rhs.username &&
        abs(lhs.dateAdded.timeIntervalSince(rhs.dateAdded)) < 1.0
    }
}
