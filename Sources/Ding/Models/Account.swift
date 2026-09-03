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

    /// The mail provider preset governing connection and authentication endpoints.
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
    /// Defaults to `false`. The future `SyncEngine` will set this flag to `true` when it detects
    /// authentication failures (such as revoked app passwords or expired credentials) during sync.
    public var needsReauthentication: Bool

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
        case dateAdded
    }

    /// Initializes a new mail account model.
    ///
    /// - Parameters:
    ///   - id: The stable account identifier. Defaults to a newly generated `UUID`.
    ///   - email: The account email address.
    ///   - provider: The mail provider preset.
    ///   - alias: An optional display alias/nickname.
    ///   - syncFrequency: The synchronization frequency. Defaults to `.useDefault`.
    ///   - notificationClickBehavior: The notification click behavior. Defaults to `.useDefault`.
    ///   - needsReauthentication: Flag indicating if the account requires re-authentication. Defaults to `false`.
    ///   - dateAdded: The timestamp when the account was created. Defaults to the current date.
    public init(
        id: UUID = UUID(),
        email: String,
        provider: MailProvider,
        alias: String? = nil,
        syncFrequency: SyncFrequency = .useDefault,
        notificationClickBehavior: NotificationClickBehavior = .useDefault,
        needsReauthentication: Bool = false,
        dateAdded: Date = Date()
    ) {
        self.id = id
        self.email = email
        self.provider = provider
        self.alias = alias
        self.syncFrequency = syncFrequency
        self.notificationClickBehavior = notificationClickBehavior
        self.needsReauthentication = needsReauthentication
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
        try container.encode(dateAdded, forKey: .dateAdded)
    }

    /// User-facing display name for UI presentation.
    ///
    /// Returns the trimmed `alias` if non-empty, otherwise falls back to `email`.
    public var displayName: String {
        if let alias = alias?.trimmingCharacters(in: .whitespacesAndNewlines), !alias.isEmpty {
            return alias
        }
        return email
    }

    /// The effective sync frequency for this account.
    ///
    /// If `syncFrequency` is set to `.useDefault`, this returns the global default from
    /// `AppPreferences.shared.defaultSyncFrequency`. When an account has a specific frequency configured,
    /// that frequency explicitly overrides the general default.
    @MainActor
    public var effectiveSyncFrequency: SyncFrequency {
        if syncFrequency == .useDefault {
            return AppPreferences.shared.defaultSyncFrequency
        }
        return syncFrequency
    }

    /// The effective notification click behavior for this account.
    ///
    /// If `notificationClickBehavior` is set to `.useDefault`, this returns the global default from
    /// `AppPreferences.shared.defaultNotificationClickBehavior`. When an account has a specific behavior configured,
    /// that behavior explicitly overrides the general default.
    @MainActor
    public var effectiveNotificationClickBehavior: NotificationClickBehavior {
        if notificationClickBehavior == .useDefault {
            return AppPreferences.shared.defaultNotificationClickBehavior
        }
        return notificationClickBehavior
    }

    public static func == (lhs: Account, rhs: Account) -> Bool {
        lhs.id == rhs.id &&
        lhs.email == rhs.email &&
        lhs.provider == rhs.provider &&
        lhs.alias == rhs.alias &&
        lhs.syncFrequency == rhs.syncFrequency &&
        lhs.notificationClickBehavior == rhs.notificationClickBehavior &&
        lhs.needsReauthentication == rhs.needsReauthentication &&
        abs(lhs.dateAdded.timeIntervalSince(rhs.dateAdded)) < 1.0
    }
}
