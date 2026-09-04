import Foundation

/// Action to perform when a mail notification banner or alert is clicked by the user.
public enum NotificationClickBehavior: String, CaseIterable, Codable, Sendable {
    /// Use the globally configured default notification click behavior from general settings.
    ///
    /// Resolution occurs at runtime by checking
    /// `AppPreferences.shared.defaultNotificationClickBehavior` when this case is encountered.
    case useDefault

    /// Take no action when the notification banner is clicked.
    case doNothing

    /// Launch the default system Mail application.
    case openMailApp

    /// Open the provider's webmail portal in the default browser.
    case openInBrowser

    /// The subset of notification click behaviors valid for global default application settings.
    ///
    /// Excludes `.useDefault` because the global general preference is itself the default.
    public static var generalOptions: [NotificationClickBehavior] {
        allCases.filter { $0 != .useDefault }
    }

    /// User-facing display name for the notification click behavior.
    public var displayName: String {
        switch self {
        case .useDefault:
            return "Default"
        case .doNothing:
            return "Do nothing"
        case .openMailApp:
            return "Open Mail app"
        case .openInBrowser:
            return "Open in browser"
        }
    }
}
