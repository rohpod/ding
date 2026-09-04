import Foundation

/// The synchronization frequency options for checking incoming mail.
public enum SyncFrequency: String, CaseIterable, Codable, Sendable {
    /// Use the globally configured default sync frequency from general settings.
    ///
    /// Resolution to an actual interval occurs at runtime by checking
    /// `AppPreferences.shared.defaultSyncFrequency` when this case is encountered.
    case useDefault

    /// Real-time push synchronization using the IMAP IDLE extension.
    case always

    /// Periodic poll every 1 minute.
    case oneMinute

    /// Periodic poll every 5 minutes.
    case fiveMinutes

    /// Periodic poll every 15 minutes.
    case fifteenMinutes

    /// Periodic poll every 30 minutes.
    case thirtyMinutes

    /// Periodic poll every 60 minutes.
    case hourly

    /// The subset of synchronization frequency options valid for global default application settings.
    ///
    /// Excludes `.useDefault` because the global general preference is itself the default.
    public static var generalOptions: [SyncFrequency] {
        allCases.filter { $0 != .useDefault }
    }

    /// User-facing display name for the sync frequency option.
    public var displayName: String {
        switch self {
        case .useDefault:
            return "Default"
        case .always:
            return "Always"
        case .oneMinute:
            return "Every 1 minute"
        case .fiveMinutes:
            return "Every 5 minutes"
        case .fifteenMinutes:
            return "Every 15 minutes"
        case .thirtyMinutes:
            return "Every 30 minutes"
        case .hourly:
            return "Hourly"
        }
    }

    /// The time interval in seconds between periodic sync polls.
    ///
    /// - Note: Sync frequency of `.always` represents real-time push synchronization using
    ///   the IMAP IDLE extension. When active, ding maintains a persistent connection and receives
    ///   immediate notifications from the mail server rather than periodically polling on a timer.
    ///   Consequently, `intervalSeconds` returns `nil` for `.always`.
    ///   For `.useDefault`, `intervalSeconds` also returns `nil` because resolution to an actual
    ///   time interval depends on the global `AppPreferences.shared.defaultSyncFrequency` setting.
    public var intervalSeconds: TimeInterval? {
        switch self {
        case .useDefault, .always:
            return nil
        case .oneMinute:
            return 60.0
        case .fiveMinutes:
            return 300.0
        case .fifteenMinutes:
            return 900.0
        case .thirtyMinutes:
            return 1800.0
        case .hourly:
            return 3600.0
        }
    }
}
