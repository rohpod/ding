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

    /// Timestamp when this account was added to ding.
    public let dateAdded: Date

    /// Initializes a new mail account model.
    ///
    /// - Parameters:
    ///   - id: The stable account identifier. Defaults to a newly generated `UUID`.
    ///   - email: The account email address.
    ///   - provider: The mail provider preset.
    ///   - alias: An optional display alias/nickname.
    ///   - syncFrequency: The synchronization frequency. Defaults to `.useDefault`.
    ///   - notificationClickBehavior: The notification click behavior. Defaults to `.useDefault`.
    ///   - dateAdded: The timestamp when the account was created. Defaults to the current date.
    public init(
        id: UUID = UUID(),
        email: String,
        provider: MailProvider,
        alias: String? = nil,
        syncFrequency: SyncFrequency = .useDefault,
        notificationClickBehavior: NotificationClickBehavior = .useDefault,
        dateAdded: Date = Date()
    ) {
        self.id = id
        self.email = email
        self.provider = provider
        self.alias = alias
        self.syncFrequency = syncFrequency
        self.notificationClickBehavior = notificationClickBehavior
        // Floor to whole seconds so date equality survives ISO-8601 serialization without fractional discrepancies
        // and never rounds into the future.
        self.dateAdded = Date(timeIntervalSince1970: floor(dateAdded.timeIntervalSince1970))
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

    public static func == (lhs: Account, rhs: Account) -> Bool {
        lhs.id == rhs.id &&
        lhs.email == rhs.email &&
        lhs.provider == rhs.provider &&
        lhs.alias == rhs.alias &&
        lhs.syncFrequency == rhs.syncFrequency &&
        lhs.notificationClickBehavior == rhs.notificationClickBehavior &&
        abs(lhs.dateAdded.timeIntervalSince(rhs.dateAdded)) < 1.0
    }
}
