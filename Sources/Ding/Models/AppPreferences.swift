import Combine
import Foundation
import os

/// The synchronization frequency options for checking incoming mail.
public enum SyncFrequency: String, CaseIterable, Codable, Sendable {
    case always
    case oneMinute
    case fiveMinutes
    case fifteenMinutes
    case thirtyMinutes
    case hourly

    /// User-facing display name for the sync frequency option.
    public var displayName: String {
        switch self {
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
    ///   Consequently, `intervalSeconds` returns `nil` for `.always`. This distinction is critical
    ///   for `SyncEngine` scheduling in later milestones.
    public var intervalSeconds: TimeInterval? {
        switch self {
        case .always:
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

/// Action to perform when a mail notification banner or alert is clicked by the user.
public enum NotificationClickBehavior: String, CaseIterable, Codable, Sendable {
    case doNothing
    case openMailApp
    case openInBrowser

    /// User-facing display name for the notification click behavior.
    public var displayName: String {
        switch self {
        case .doNothing:
            return "Do nothing"
        case .openMailApp:
            return "Open Mail app"
        case .openInBrowser:
            return "Open in browser"
        }
    }
}

/// A centralized, reactive preferences store managing General-tab user settings.
///
/// ## Concurrency & Observation Choice: `ObservableObject` vs `@Observable`
/// While Swift 5.9 introduced the `@Observable` macro in the `Observation` framework,
/// the framework requires macOS 14.0 or newer at runtime. Because ding specifies
/// a deployment target of macOS 13.0 (`platforms: [.macOS(.v13)]`), using `@Observable` causes
/// compilation failure (`'Observable()' is only available in macOS 14.0 or newer`).
///
/// We therefore use Combine's `ObservableObject` with `@Published` properties, bound strictly to
/// `@MainActor`. In Swift 6 strict concurrency, a `@MainActor`-isolated `ObservableObject` guarantees
/// actor safety across SwiftUI views and non-UI callers (such as `AppDelegate`) without data races.
@MainActor
public final class AppPreferences: ObservableObject {
    private static let logger = Logger(subsystem: "com.ding.mac", category: "Preferences")

    /// The shared singleton instance of `AppPreferences`.
    public static let shared = AppPreferences()

    // MARK: - Storage Keys

    private enum Keys {
        static let defaultSyncFrequency = "ding.preference.defaultSyncFrequency"
        static let defaultNotificationClickBehavior = "ding.preference.defaultNotificationClickBehavior"
        static let isMenuBarIconVisible = "ding.preference.isMenuBarIconVisible"
        static let isOpenAtLoginEnabled = "ding.preference.isOpenAtLoginEnabled"
    }

    private let userDefaults: UserDefaults

    // MARK: - Properties

    /// The default polling frequency or push sync mode for mail accounts.
    ///
    /// Defaults to `.always` (real-time push via IMAP IDLE).
    @Published public var defaultSyncFrequency: SyncFrequency {
        didSet {
            userDefaults.set(defaultSyncFrequency.rawValue, forKey: Keys.defaultSyncFrequency)
            Self.logger.debug("Saved defaultSyncFrequency: \(self.defaultSyncFrequency.rawValue, privacy: .public)")
        }
    }

    /// The behavior triggered when the user clicks a notification.
    ///
    /// Defaults to `.doNothing`.
    @Published public var defaultNotificationClickBehavior: NotificationClickBehavior {
        didSet {
            userDefaults.set(defaultNotificationClickBehavior.rawValue, forKey: Keys.defaultNotificationClickBehavior)
            Self.logger.debug("Saved defaultNotificationClickBehavior: \(self.defaultNotificationClickBehavior.rawValue, privacy: .public)")
        }
    }

    /// Indicates whether ding's icon is shown in the macOS menu bar.
    ///
    /// Defaults to `true`. When set to `false`, the icon is removed from the system status bar,
    /// and the app can be accessed by relaunching it from Applications or Spotlight.
    @Published public var isMenuBarIconVisible: Bool {
        didSet {
            userDefaults.set(isMenuBarIconVisible, forKey: Keys.isMenuBarIconVisible)
            Self.logger.debug("Saved isMenuBarIconVisible: \(self.isMenuBarIconVisible, privacy: .public)")
        }
    }

    /// Indicates whether ding is configured to automatically launch upon user login.
    ///
    /// Defaults to `false`. This preference mirrors the registration status managed via `SMAppService.mainApp`.
    @Published public var isOpenAtLoginEnabled: Bool {
        didSet {
            userDefaults.set(isOpenAtLoginEnabled, forKey: Keys.isOpenAtLoginEnabled)
            Self.logger.debug("Saved isOpenAtLoginEnabled: \(self.isOpenAtLoginEnabled, privacy: .public)")
        }
    }

    // MARK: - Initialization

    /// Initializes a preferences store backed by the specified `UserDefaults`.
    ///
    /// - Parameter userDefaults: The storage container to use. Defaults to `.standard`.
    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        // defaultSyncFrequency: default .always
        if let rawSync = userDefaults.string(forKey: Keys.defaultSyncFrequency),
           let frequency = SyncFrequency(rawValue: rawSync) {
            self.defaultSyncFrequency = frequency
        } else {
            self.defaultSyncFrequency = .always
        }

        // defaultNotificationClickBehavior: default .doNothing
        if let rawBehavior = userDefaults.string(forKey: Keys.defaultNotificationClickBehavior),
           let behavior = NotificationClickBehavior(rawValue: rawBehavior) {
            self.defaultNotificationClickBehavior = behavior
        } else {
            self.defaultNotificationClickBehavior = .doNothing
        }

        // isMenuBarIconVisible: default true
        if userDefaults.object(forKey: Keys.isMenuBarIconVisible) != nil {
            self.isMenuBarIconVisible = userDefaults.bool(forKey: Keys.isMenuBarIconVisible)
        } else {
            self.isMenuBarIconVisible = true
        }

        // isOpenAtLoginEnabled: default false
        if userDefaults.object(forKey: Keys.isOpenAtLoginEnabled) != nil {
            self.isOpenAtLoginEnabled = userDefaults.bool(forKey: Keys.isOpenAtLoginEnabled)
        } else {
            self.isOpenAtLoginEnabled = false
        }

        Self.logger.info("AppPreferences initialized (sync: \(self.defaultSyncFrequency.rawValue, privacy: .public), icon: \(self.isMenuBarIconVisible, privacy: .public), loginItem: \(self.isOpenAtLoginEnabled, privacy: .public))")
    }
}
