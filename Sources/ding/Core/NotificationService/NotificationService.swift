import Foundation
import os
import UserNotifications

/// Standard keys used within `UNNotificationContent.userInfo` dictionaries.
public enum NotificationUserInfoKey {
    /// The string representation of the account UUID that received the mail.
    public static let accountID = "accountID"

    /// The array of string representations of the message IMAP unique identifiers (UIDs).
    public static let messageUIDs = "messageUIDs"
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

    /// Formats the notification body text based on incoming messages.
    ///
    /// Single message layout:
    /// From: <sender name or email>
    /// Sub: <subject (up to 3 lines, followed by ... if truncated)>
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
            return "\(messages.count) new messages"
        }
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
public final class NotificationService: Sendable {
    private static let logger = Logger(subsystem: "com.ding.mac", category: "NotificationService")

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
            Self.logger.info("Sent notification for \(event.messages.count, privacy: .public) new message(s) in \(account.displayName, privacy: .public)")
        } catch {
            Self.logger.error("Failed to deliver notification for account \(account.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
