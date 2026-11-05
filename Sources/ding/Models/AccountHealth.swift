import Foundation

/// A point-in-time view of whether ding is really watching an account.
///
/// Health lives in memory only. It is deliberately independent of `SyncState.lastSyncedAt`, which is written only
/// when new mail arrives and so would make a quiet inbox look stale.
public struct AccountHealth: Equatable, Sendable {
    /// How ding is currently watching the account.
    public enum Connection: Equatable, Sendable {
        /// The worker has started but has not yet completed a check.
        case connecting
        /// A persistent IDLE connection is open.
        case push
        /// The account is checked on a timer. `idleUnsupported` is true when push was requested but the server lacks it.
        case polling(intervalSeconds: Int, idleUnsupported: Bool)
        /// The last attempt failed and the worker is backing off before it retries.
        case retrying
    }

    public var connection: Connection

    /// When a connect-and-fetch last succeeded, even if it found no new mail.
    public var lastSuccessfulCheck: Date?

    /// Failures since the last success. Unlike the worker's backoff counter, a reconnect request does not reset it.
    public var consecutiveFailures: Int

    /// The most recent failure's description. May show in the UI but must never be logged publicly.
    public var lastErrorMessage: String?

    /// Failures tolerated before the UI warns. Backoff is 5/10/20/40s, so about 75 seconds of failure.
    public static let degradedThreshold = 4

    /// Failures after which the user is notified, since a hidden menu bar icon makes the menu warning invisible.
    /// About 20 minutes of failure.
    public static let notificationThreshold = 10

    public var isDegraded: Bool { consecutiveFailures >= Self.degradedThreshold }

    public init(
        connection: Connection = .connecting,
        lastSuccessfulCheck: Date? = nil,
        consecutiveFailures: Int = 0,
        lastErrorMessage: String? = nil
    ) {
        self.connection = connection
        self.lastSuccessfulCheck = lastSuccessfulCheck
        self.consecutiveFailures = consecutiveFailures
        self.lastErrorMessage = lastErrorMessage
    }
}

/// Turns an account's health into the one-line status shown in the menu and in Settings.
///
/// Times are absolute ("checked 2:41 PM") rather than relative, because a menu-bar menu is not re-rendered while it
/// is closed and a string like "3 min ago" would go stale.
public enum AccountHealthFormatter {
    public static func summary(
        account: Account,
        health: AccountHealth?,
        isNetworkAvailable: Bool,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        if account.needsReauthentication {
            return "Password needed"
        }
        if !isNetworkAvailable {
            return "Offline"
        }
        guard let health else {
            return "Connecting…"
        }
        if health.connection == .connecting && health.lastSuccessfulCheck == nil {
            return "Connecting…"
        }

        let checked = health.lastSuccessfulCheck.map {
            formattedTime($0, now: now, calendar: calendar, locale: locale)
        }

        if health.isDegraded {
            return checked.map { "Can't connect, last checked \($0)" } ?? "Can't connect"
        }

        switch health.connection {
        case .connecting:
            // Reconnecting after an earlier success: the history is still the most useful thing to show.
            return checked.map { "Connecting, last checked \($0)" } ?? "Connecting…"
        case .retrying:
            return "Reconnecting…"
        case .push:
            return checked.map { "Live, checked \($0)" } ?? "Live"
        case .polling(let seconds, let idleUnsupported):
            let minutes = max(1, Int((Double(seconds) / 60).rounded()))
            let cadence = "Every \(minutes) min" + (idleUnsupported ? " (no push support)" : "")
            return checked.map { "\(cadence), checked \($0)" } ?? cadence
        }
    }

    /// The short time on the same calendar day as `now`, otherwise the short date and time.
    static func formattedTime(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.timeStyle = .short
        formatter.dateStyle = calendar.isDate(date, inSameDayAs: now) ? .none : .short
        return formatter.string(from: date)
    }
}
