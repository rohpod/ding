import Combine
import Foundation
import os


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
    private static let logger = Logger(subsystem: DingLog.subsystem, category: "Preferences")

    /// The shared singleton instance of `AppPreferences`.
    public static let shared = AppPreferences()

    // MARK: - Storage Keys

    private enum Keys {
        static let defaultSyncFrequency = "ding.preference.defaultSyncFrequency"
        static let defaultNotificationClickBehavior = "ding.preference.defaultNotificationClickBehavior"
        static let isMenuBarIconVisible = "ding.preference.isMenuBarIconVisible"
        static let isOpenAtLoginEnabled = "ding.preference.isOpenAtLoginEnabled"
        static let isAutomaticUpdateCheckEnabled = "ding.preference.isAutomaticUpdateCheckEnabled"
        static let isAutomaticUpdateInstallEnabled = "ding.preference.isAutomaticUpdateInstallEnabled"
        static let lastUpdateCheckDate = "ding.preference.lastUpdateCheckDate"
    }

    private let userDefaults: UserDefaults

    // MARK: - Properties

    /// The default polling frequency or push sync mode for mail accounts.
    ///
    /// Defaults to `.always` (real-time push via IMAP IDLE).
    @Published public var defaultSyncFrequency: SyncFrequency {
        didSet {
            if defaultSyncFrequency == .useDefault {
                defaultSyncFrequency = .always
                return
            }
            userDefaults.set(defaultSyncFrequency.rawValue, forKey: Keys.defaultSyncFrequency)
            Self.logger.debug("Saved defaultSyncFrequency: \(self.defaultSyncFrequency.rawValue, privacy: .public)")
        }
    }

    /// The behavior triggered when the user clicks a notification.
    ///
    /// Defaults to `.doNothing`.
    @Published public var defaultNotificationClickBehavior: NotificationClickBehavior {
        didSet {
            if defaultNotificationClickBehavior == .useDefault {
                defaultNotificationClickBehavior = .doNothing
                return
            }
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

    /// Indicates whether ding is configured to automatically check for updates in the background.
    ///
    /// Defaults to `true`.
    @Published public var isAutomaticUpdateCheckEnabled: Bool {
        didSet {
            userDefaults.set(isAutomaticUpdateCheckEnabled, forKey: Keys.isAutomaticUpdateCheckEnabled)
            Self.logger.debug("Saved isAutomaticUpdateCheckEnabled: \(self.isAutomaticUpdateCheckEnabled, privacy: .public)")
        }
    }

    /// Indicates whether ding is configured to automatically download and install updates in the background.
    ///
    /// Defaults to `false`.
    @Published public var isAutomaticUpdateInstallEnabled: Bool {
        didSet {
            userDefaults.set(isAutomaticUpdateInstallEnabled, forKey: Keys.isAutomaticUpdateInstallEnabled)
            Self.logger.debug("Saved isAutomaticUpdateInstallEnabled: \(self.isAutomaticUpdateInstallEnabled, privacy: .public)")
        }
    }

    /// The timestamp when an update check was last performed, if any.
    ///
    /// Defaults to `nil`.
    @Published public var lastUpdateCheckDate: Date? {
        didSet {
            userDefaults.set(lastUpdateCheckDate, forKey: Keys.lastUpdateCheckDate)
            Self.logger.debug("Saved lastUpdateCheckDate: \(String(describing: self.lastUpdateCheckDate), privacy: .public)")
        }
    }

    // MARK: - Initialization

    /// Initializes a preferences store backed by the specified `UserDefaults`.
    ///
    /// If a preference value has not yet been set in the store, the documented
    /// default value is assigned automatically.
    ///
    /// - Parameter userDefaults: The `UserDefaults` instance to read from and write to.
    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        // defaultSyncFrequency: default .always
        if let rawFrequency = userDefaults.string(forKey: Keys.defaultSyncFrequency),
           let frequency = SyncFrequency(rawValue: rawFrequency),
           frequency != .useDefault {
            self.defaultSyncFrequency = frequency
        } else {
            self.defaultSyncFrequency = .always
        }

        // defaultNotificationClickBehavior: default .doNothing
        if let rawBehavior = userDefaults.string(forKey: Keys.defaultNotificationClickBehavior),
           let behavior = NotificationClickBehavior(rawValue: rawBehavior),
           behavior != .useDefault {
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

        // isAutomaticUpdateCheckEnabled: default true
        if userDefaults.object(forKey: Keys.isAutomaticUpdateCheckEnabled) != nil {
            self.isAutomaticUpdateCheckEnabled = userDefaults.bool(forKey: Keys.isAutomaticUpdateCheckEnabled)
        } else {
            self.isAutomaticUpdateCheckEnabled = true
        }

        // isAutomaticUpdateInstallEnabled: default false
        if userDefaults.object(forKey: Keys.isAutomaticUpdateInstallEnabled) != nil {
            self.isAutomaticUpdateInstallEnabled = userDefaults.bool(forKey: Keys.isAutomaticUpdateInstallEnabled)
        } else {
            self.isAutomaticUpdateInstallEnabled = false
        }

        // lastUpdateCheckDate: default nil
        self.lastUpdateCheckDate = userDefaults.object(forKey: Keys.lastUpdateCheckDate) as? Date

        Self.logger.info("AppPreferences initialized (sync: \(self.defaultSyncFrequency.rawValue, privacy: .public), icon: \(self.isMenuBarIconVisible, privacy: .public), loginItem: \(self.isOpenAtLoginEnabled, privacy: .public), autoCheck: \(self.isAutomaticUpdateCheckEnabled, privacy: .public), autoInstall: \(self.isAutomaticUpdateInstallEnabled, privacy: .public))")
    }
}
