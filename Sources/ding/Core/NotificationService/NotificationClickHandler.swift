import AppKit
import Foundation
import os
import UserNotifications

/// Pure resolver for determining the effective notification click behavior for an account.
public enum NotificationActionResolver {
    /// Resolves the effective notification click behavior for an account,
    /// resolving `.useDefault` against the provided fallback preference.
    ///
    /// - Parameters:
    ///   - account: The account model.
    ///   - defaultBehavior: The default preference from `AppPreferences`.
    /// - Returns: The resolved actionable `NotificationClickBehavior` (`.doNothing`, `.openMailApp`, or `.openInBrowser`).
    public static func resolveBehavior(
        for account: Account,
        defaultBehavior: NotificationClickBehavior
    ) -> NotificationClickBehavior {
        if account.notificationClickBehavior == .useDefault {
            return defaultBehavior == .useDefault ? .doNothing : defaultBehavior
        }
        return account.notificationClickBehavior
    }
}

/// Pure router that executes system actions associated with a resolved `NotificationClickBehavior`.
public struct NotificationActionRouter {
    /// Executes the appropriate system action for the given click behavior and provider.
    ///
    /// Executes the appropriate system action for the given click behavior and provider.
    ///
    /// - Parameters:
    ///   - behavior: The resolved click behavior to execute.
    ///   - provider: The mail provider associated with the account.
    ///   - defaultMailAppURLResolver: Closure providing the default mail client application bundle URL.
    ///   - urlOpener: Closure used to open URLs. Defaults to `NSWorkspace.shared.open(_:)`.
    /// - Returns: `true` if an action was executed successfully; `false` otherwise.
    @discardableResult
    public static func execute(
        behavior: NotificationClickBehavior,
        provider: MailProvider,
        defaultMailAppURLResolver: () -> URL? = {
            NSWorkspace.shared.urlForApplication(toOpen: URL(string: "mailto:")!)
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.mail")
        },
        urlOpener: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) -> Bool {
        switch behavior {
        case .doNothing, .useDefault:
            return false

        case .openMailApp:
            // Open the default mail application installed on the user's Mac.
            // Resolving the application URL for mailto: returns the default client (e.g. file:///System/Applications/Mail.app/).
            // Opening the application bundle URL directly activates/launches the mail client
            // without passing invalid URL parameters or prompting "unable to open URL message:".
            if let mailAppURL = defaultMailAppURLResolver() {
                return urlOpener(mailAppURL)
            }
            return false

        case .openInBrowser:
            // Open provider's inbox in the default web browser.
            // Deep-linking to individual messages varies by provider and is scoped out of v1.
            let webmailURL = provider.webmailURL
            return urlOpener(webmailURL)
        }
    }
}

/// Delegate for `UNUserNotificationCenter` handling foreground presentation and click routing.
public final class NotificationClickHandler: NSObject, UNUserNotificationCenterDelegate, Sendable {
    private static let logger = Logger(subsystem: "com.ding.mac", category: "NotificationClickHandler")

    /// Shared singleton instance of `NotificationClickHandler`.
    public static let shared = NotificationClickHandler()

    /// Timestamp of the most recent notification click event, used to suppress reopening Settings.
    @MainActor
    public static var lastNotificationClickTime: Date = .distantPast

    public override init() {
        super.init()
    }

    /// Presents incoming notifications with a banner and sound even while ding is the active application.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        return [.banner, .sound]
    }

    /// Handles user clicks on posted notifications.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        guard let accountIDString = userInfo[NotificationUserInfoKey.accountID] as? String,
              let accountID = UUID(uuidString: accountIDString) else {
            Self.logger.warning("Received notification response without valid account ID in userInfo.")
            return
        }

        await MainActor.run {
            Self.lastNotificationClickTime = Date()
            self.handleClick(forAccountID: accountID)
        }
    }

    @MainActor
    private func handleClick(forAccountID accountID: UUID) {
        guard let account = AccountManager.shared.accounts.first(where: { $0.id == accountID }) else {
            Self.logger.warning("Account \(accountID.uuidString, privacy: .public) was deleted or not found; ignoring click.")
            return
        }

        let behavior = NotificationActionResolver.resolveBehavior(
            for: account,
            defaultBehavior: AppPreferences.shared.defaultNotificationClickBehavior
        )

        Self.logger.info("Handling notification click for account \(account.displayName, privacy: .public) with resolved behavior: \(behavior.rawValue, privacy: .public)")

        let success = NotificationActionRouter.execute(
            behavior: behavior,
            provider: account.provider
        )

        if behavior != .doNothing && !success {
            Self.logger.error("Failed to execute action for behavior \(behavior.rawValue, privacy: .public)")
        }
    }
}
