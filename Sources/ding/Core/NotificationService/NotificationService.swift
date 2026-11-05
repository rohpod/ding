import Foundation
import os
import UserNotifications

/// Standard keys used within `UNNotificationContent.userInfo` dictionaries.
public enum NotificationUserInfoKey {
    /// The string representation of the account UUID that received the mail.
    public static let accountID = "accountID"

    /// The array of string representations of the message IMAP unique identifiers (UIDs).
    public static let messageUIDs = "messageUIDs"

    /// Distinguishes notification purposes; absent for ordinary new-mail notifications.
    public static let kind = "kind"

    /// The `kind` value for notifications asking the user to update an account's app password.
    public static let reauthenticationKind = "reauthentication"

    /// The `kind` value for notifications reporting that an account has been unreachable for a long time.
    public static let connectionProblemKind = "connectionProblem"
}

/// Pure helper responsible for formatting and constructing `UNMutableNotificationContent`
/// instances from `NewMailEvent` and `Account` data models.
public struct NotificationContentBuilder {
    /// Formats the sender string cleanly:
    /// - If a display name is present (e.g. "Rohan Poddar <email>"), removes the email ID and returns only the display name ("Rohan Poddar").
    /// - Otherwise returns only the email ID (e.g. "rohan@example.com").
    /// - Constrained to a single line.
    public static func formatSender(_ from: String) -> String {
        let trimmed = from.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = trimmed
        if let angleStart = trimmed.firstIndex(of: "<") {
            let namePart = trimmed[..<angleStart].trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"\'")))
            if !namePart.isEmpty {
                result = namePart
            } else if let angleEnd = trimmed.firstIndex(of: ">"), angleEnd > angleStart {
                let emailPart = trimmed[trimmed.index(after: angleStart)..<angleEnd].trimmingCharacters(in: .whitespacesAndNewlines)
                if !emailPart.isEmpty {
                    result = emailPart
                }
            }
        }
        return result.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Formats and truncates the subject line to up to 3 lines, appending "..." if truncated.
    public static func formatSubject(_ subject: String, maxLines: Int = 3, maxTotalLength: Int = 150) -> String {
        let cleanSubject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSubject.isEmpty else { return "" }

        // Handle explicit newline separation
        let lines = cleanSubject.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if lines.count > maxLines {
            let truncatedLines = lines.prefix(maxLines).joined(separator: "\n")
            return truncatedLines.trimmingCharacters(in: .whitespacesAndNewlines) + "..."
        }

        // Handle total character length (approx 3 lines of ~50 chars each)
        if cleanSubject.count > maxTotalLength {
            let index = cleanSubject.index(cleanSubject.startIndex, offsetBy: maxTotalLength - 3)
            return String(cleanSubject[..<index]).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
        }

        return cleanSubject
    }

    /// The most sender names listed in a multi-message notification.
    static let maxListedSenders = 3

    /// The `threadIdentifier` that stacks one account's mail notifications together.
    public static func threadIdentifier(forAccountID id: UUID) -> String {
        "ding.account.\(id.uuidString)"
    }

    /// Formats the notification body text based on incoming messages.
    ///
    /// Single message layout:
    /// From: <sender name or email>
    /// Sub: <subject (up to 3 lines, followed by ... if truncated)>
    ///
    /// Multiple messages layout (`messages` ascending by UID, senders listed newest first):
    /// <N> new messages
    /// From: <up to 3 distinct senders>[ and others]
    public static func formatBody(for messages: [MessageSummary]) -> String {
        if messages.count == 1, let msg = messages.first {
            var bodyComponents: [String] = []

            let sender = formatSender(msg.from)
            if !sender.isEmpty {
                bodyComponents.append("From: \(sender)")
            }

            let subject = formatSubject(msg.subject)
            if !subject.isEmpty {
                bodyComponents.append("Sub: \(subject)")
            }

            if bodyComponents.isEmpty {
                return "New message"
            }
            return bodyComponents.joined(separator: "\n")
        } else if messages.isEmpty {
            return "New mail"
        } else {
            let headline = "\(messages.count) new messages"
            guard let senders = formatSenderList(for: messages) else {
                return headline
            }
            return "\(headline)\n\(senders)"
        }
    }

    /// The `From:` line for a batch, or nil when no sender is known.
    ///
    /// Walks newest first, dedupes case-insensitively and lists at most `maxListedSenders`. " and others" is added
    /// when more senders exist than are shown, or when any message has no sender because its envelope was not fetched.
    private static func formatSenderList(for messages: [MessageSummary]) -> String? {
        var listed: [String] = []
        var seen = Set<String>()
        var hasMoreSenders = false
        var hasUnknownSender = false

        for message in messages.reversed() {
            let sender = formatSender(message.from)
            if sender.isEmpty {
                hasUnknownSender = true
                continue
            }
            guard seen.insert(sender.lowercased()).inserted else { continue }
            if listed.count < maxListedSenders {
                listed.append(sender)
            } else {
                hasMoreSenders = true
            }
        }

        guard !listed.isEmpty else { return nil }
        let suffix = (hasMoreSenders || hasUnknownSender) ? " and others" : ""
        return "From: \(listed.joined(separator: ", "))\(suffix)"
    }

    /// Constructs a `UNMutableNotificationContent` payload for a given mail event and account.
    ///
    /// - Parameters:
    ///   - event: The detected new mail event containing account ID and message summaries.
    ///   - account: The target mail account model.
    /// - Returns: A populated `UNMutableNotificationContent` ready for scheduling.
    public static func buildContent(for event: NewMailEvent, account: Account) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = account.displayName.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        content.body = formatBody(for: event.messages)
        content.sound = .default

        let uids = event.messages.map { String($0.uid) }
        content.userInfo = [
            NotificationUserInfoKey.accountID: event.accountID.uuidString,
            NotificationUserInfoKey.messageUIDs: uids
        ]
        content.threadIdentifier = threadIdentifier(forAccountID: account.id)

        return content
    }

    /// Constructs the payload telling the user that an account was signed out and needs a new app password.
    public static func buildReauthenticationContent(account: Account) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = account.displayName.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        content.body = "ding can't sign in to this account, so new mail won't be announced. Click to enter a new \(account.credentialName)."
        content.sound = .default
        content.userInfo = [
            NotificationUserInfoKey.accountID: account.id.uuidString,
            NotificationUserInfoKey.kind: NotificationUserInfoKey.reauthenticationKind
        ]
        return content
    }

    /// Constructs the payload telling the user that ding has been unable to reach an account for a long time.
    ///
    /// Deliberately omits the error text, which can echo a server name or username.
    public static func buildConnectionProblemContent(account: Account) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = account.displayName.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        content.body = "ding hasn't been able to reach this account for a while, so new mail won't be announced. Click to check its status in Settings."
        content.sound = .default
        content.userInfo = [
            NotificationUserInfoKey.accountID: account.id.uuidString,
            NotificationUserInfoKey.kind: NotificationUserInfoKey.connectionProblemKind
        ]
        return content
    }

    /// Constructs the payload reporting that a manual check could not reach one or more accounts.
    public static func buildCheckFailedContent(failedCount: Int) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Couldn't check mail"
        content.body = failedCount == 1
            ? "ding couldn't reach 1 account. Check your connection and try again."
            : "ding couldn't reach \(failedCount) accounts. Check your connection and try again."
        content.sound = .default
        return content
    }

    /// Constructs a `UNMutableNotificationContent` payload for a zero-unread-mail notification.
    public static func buildZeroUnreadContent() -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "You have 0 unread emails"
        content.sound = .default
        return content
    }

    /// Constructs a `UNMutableNotificationContent` payload for a per-account unread mail notification.
    ///
    /// - Parameters:
    ///   - account: The target mail account model.
    ///   - unreadCount: The number of unread emails.
    /// - Returns: A populated `UNMutableNotificationContent` ready for scheduling.
    public static func buildAccountUnreadContent(account: Account, unreadCount: Int) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = account.displayName.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let emailWord = unreadCount == 1 ? "unread email" : "unread emails"
        content.body = "\(unreadCount) \(emailWord)"
        content.sound = .default
        content.userInfo = [
            NotificationUserInfoKey.accountID: account.id.uuidString
        ]
        content.threadIdentifier = threadIdentifier(forAccountID: account.id)
        return content
    }
}

/// Service wrapping `UNUserNotificationCenter` for posting notifications and requesting permissions.
///
/// ## Concurrency & App Bundle Safety
/// `NotificationService` is isolated to `@MainActor` and coordinates with `NotificationPermissionManager`.
/// In unbundled environments (such as CLI-based unit tests), interacting with `UNUserNotificationCenter`
/// throws `NSInternalInconsistencyException`. This service guards calls against
/// `NotificationPermissionManager.isRunningInAppBundle`.
@MainActor
public final class NotificationService {
    private static let logger = Logger(subsystem: DingLog.subsystem, category: "NotificationService")

    /// Shared singleton instance of `NotificationService`.
    public static let shared = NotificationService()

    private let permissionManager: NotificationPermissionManager

    /// Initializes a notification service.
    ///
    /// - Parameter permissionManager: The permission manager to query authorization status from.
    public init(permissionManager: NotificationPermissionManager = .shared) {
        self.permissionManager = permissionManager
    }

    /// Checks the current notification authorization status and requests authorization if not yet determined.
    ///
    /// If authorization has already been granted or denied, this method safely does nothing to avoid redundant calls.
    public func requestPermissionIfNeeded() async {
        let status = await permissionManager.currentAuthorizationStatus()
        switch status {
        case .notDetermined:
            Self.logger.info("Notification authorization status is .notDetermined. Requesting permission...")
            guard NotificationPermissionManager.isRunningInAppBundle else {
                Self.logger.warning("Running outside an .app bundle; skipping UNUserNotificationCenter request.")
                return
            }

            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                Self.logger.info("Notification authorization request completed. Granted: \(granted, privacy: .public)")
            } catch {
                Self.logger.error("Failed to request notification authorization: \(error.localizedDescription, privacy: .public)")
            }

        case .authorized, .provisional:
            Self.logger.debug("Notification permission already authorized.")

        case .denied:
            Self.logger.debug("Notification permission is currently denied by user.")

        @unknown default:
            Self.logger.debug("Notification permission status is unknown: \(status.rawValue, privacy: .public)")
        }
    }

    /// Builds and delivers a user notification for a new mail event.
    ///
    /// - Parameters:
    ///   - event: The new mail event containing the newly discovered messages.
    ///   - account: The account model associated with the event.
    public func send(for event: NewMailEvent, account: Account) async {
        guard NotificationPermissionManager.isRunningInAppBundle else {
            Self.logger.warning("Running outside an .app bundle; skipping notification delivery for account \(account.id.uuidString, privacy: .public)")
            return
        }

        let content = NotificationContentBuilder.buildContent(for: event, account: account)
        let identifier = "ding.mail.\(account.id.uuidString).\(UUID().uuidString)"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)

        do {
            try await UNUserNotificationCenter.current().add(request)
            Self.logger.info("Sent notification for \(event.messages.count, privacy: .public) new message(s) for account \(account.id.uuidString, privacy: .public)")
        } catch {
            Self.logger.error("Failed to deliver notification for account \(account.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Builds and delivers a notification asking the user to re-enter an account's app password.
    public func sendReauthenticationNeededNotification(account: Account) async {
        guard NotificationPermissionManager.isRunningInAppBundle else {
            Self.logger.warning("Running outside an .app bundle; skipping re-authentication notification for account \(account.id.uuidString, privacy: .public)")
            return
        }

        let content = NotificationContentBuilder.buildReauthenticationContent(account: account)
        let identifier = "ding.mail.reauth.\(account.id.uuidString)"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)

        do {
            try await UNUserNotificationCenter.current().add(request)
            Self.logger.info("Sent re-authentication notification for account \(account.id.uuidString, privacy: .public)")
        } catch {
            Self.logger.error("Failed to deliver re-authentication notification for account \(account.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Builds and delivers a notification saying an account has been unreachable for a long time.
    public func sendConnectionProblemNotification(account: Account) async {
        guard NotificationPermissionManager.isRunningInAppBundle else {
            Self.logger.warning("Running outside an .app bundle; skipping connection-problem notification for account \(account.id.uuidString, privacy: .public)")
            return
        }

        let content = NotificationContentBuilder.buildConnectionProblemContent(account: account)
        let identifier = "ding.mail.connection.\(account.id.uuidString)"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)

        do {
            try await UNUserNotificationCenter.current().add(request)
            Self.logger.info("Sent connection-problem notification for account \(account.id.uuidString, privacy: .public)")
        } catch {
            Self.logger.error("Failed to deliver connection-problem notification for account \(account.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Builds and delivers a notification reporting that a manual check failed.
    public func sendCheckFailedNotification(failedCount: Int) async {
        guard NotificationPermissionManager.isRunningInAppBundle else {
            Self.logger.warning("Running outside an .app bundle; skipping check-failed notification delivery.")
            return
        }

        let content = NotificationContentBuilder.buildCheckFailedContent(failedCount: failedCount)
        let request = UNNotificationRequest(identifier: "ding.mail.checkFailed.\(UUID().uuidString)", content: content, trigger: nil)

        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            Self.logger.error("Failed to deliver check-failed notification: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Builds and delivers a user notification indicating zero unread emails across checked accounts.
    public func sendZeroUnreadNotification() async {
        guard NotificationPermissionManager.isRunningInAppBundle else {
            Self.logger.warning("Running outside an .app bundle; skipping zero-unread notification delivery.")
            return
        }

        let content = NotificationContentBuilder.buildZeroUnreadContent()
        let identifier = "ding.mail.zeroUnread.\(UUID().uuidString)"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)

        do {
            try await UNUserNotificationCenter.current().add(request)
            Self.logger.info("Sent zero-unread notification")
        } catch {
            Self.logger.error("Failed to deliver zero-unread notification: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Builds and delivers a user notification for an account's unread mail count.
    ///
    /// - Parameters:
    ///   - account: The target mail account model.
    ///   - unreadCount: The number of unread emails.
    public func sendAccountUnreadNotification(account: Account, unreadCount: Int) async {
        guard NotificationPermissionManager.isRunningInAppBundle else {
            Self.logger.warning("Running outside an .app bundle; skipping unread notification delivery for account \(account.id.uuidString, privacy: .public)")
            return
        }

        let content = NotificationContentBuilder.buildAccountUnreadContent(account: account, unreadCount: unreadCount)
        let identifier = "ding.mail.unread.\(account.id.uuidString).\(UUID().uuidString)"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)

        do {
            try await UNUserNotificationCenter.current().add(request)
            Self.logger.info("Sent unread notification for \(unreadCount, privacy: .public) unread email(s) for account \(account.id.uuidString, privacy: .public)")
        } catch {
            Self.logger.error("Failed to deliver unread notification for account \(account.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
