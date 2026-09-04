import AppKit
import Foundation
import os
import UserNotifications

/// Errors specific to notification permission management.
public enum NotificationError: LocalizedError, Sendable {
    case requiresAppBundle

    public var errorDescription: String? {
        switch self {
        case .requiresAppBundle:
            return "Notification authorization requires ding to be run from an application bundle (ding.app)."
        }
    }
}

/// Manages querying system notification permissions, requesting authorization, and deep-linking to macOS System Settings.
@MainActor
public final class NotificationPermissionManager: Sendable {
    private static let logger = Logger(subsystem: "com.ding.mac", category: "Notifications")

    /// Shared singleton instance of `NotificationPermissionManager`.
    public static let shared = NotificationPermissionManager()

    private let statusProvider: (@Sendable () async -> UNAuthorizationStatus)?
    private let authorizationRequester: (@Sendable () async throws -> Bool)?

    /// Indicates whether the current process is executing within a valid `.app` application bundle.
    public static var isRunningInAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Initializes a notification permission manager.
    ///
    /// - Parameters:
    ///   - statusProvider: An optional custom provider for authorization status, useful for testing.
    ///   - authorizationRequester: An optional custom provider for authorization requests, useful for testing.
    public init(
        statusProvider: (@Sendable () async -> UNAuthorizationStatus)? = nil,
        authorizationRequester: (@Sendable () async throws -> Bool)? = nil
    ) {
        self.statusProvider = statusProvider
        self.authorizationRequester = authorizationRequester
    }

    /// Queries the current notification authorization status from the system.
    ///
    /// - Returns: The current `UNAuthorizationStatus` (`.authorized`, `.denied`, `.notDetermined`, or `.provisional`).
    public func currentAuthorizationStatus() async -> UNAuthorizationStatus {
        if let statusProvider = statusProvider {
            return await statusProvider()
        }

        // UNUserNotificationCenter.current() throws an uncaught NSInternalInconsistencyException
        // if called from an unbundled binary (e.g. during swift run or unit test execution)
        // because bundleProxyForCurrentProcess is nil. We check isRunningInAppBundle to prevent crashes.
        guard Self.isRunningInAppBundle else {
            Self.logger.info("Running outside of an .app bundle; default to .notDetermined.")
            return .notDetermined
        }

        let settings = await UNUserNotificationCenter.current().notificationSettings()
        Self.logger.debug("Current notification authorization status: \(settings.authorizationStatus.rawValue)")
        return settings.authorizationStatus
    }

    /// Requests user authorization for notifications (alert, sound, badge).
    ///
    /// In macOS, calling this method prompts the system to register ding in the
    /// System Settings Notifications registry and displays the authorization prompt to the user.
    ///
    /// - Returns: `true` if authorization was granted; `false` otherwise.
    /// - Throws: `NotificationError.requiresAppBundle` if run outside a valid `.app` bundle, or system errors.
    @discardableResult
    public func requestAuthorization() async throws -> Bool {
        if let authorizationRequester = authorizationRequester {
            return try await authorizationRequester()
        }

        guard Self.isRunningInAppBundle else {
            Self.logger.warning("Notification authorization requested outside of an .app bundle.")
            throw NotificationError.requiresAppBundle
        }

        let center = UNUserNotificationCenter.current()
        let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        Self.logger.info("Notification authorization granted: \(granted)")
        return granted
    }

    /// Opens macOS System Settings directly to the Notifications configuration pane.
    ///
    /// ## macOS Deep-link URL Scheme Details
    /// - In macOS 13+ (Ventura and later), System Settings panes are modular extension plugins.
    ///   The URL targeting ding's notifications settings pane on macOS 13+ is:
    ///   `x-apple.systempreferences:com.apple.Notifications-Settings.extension`
    /// - If the direct extension URL cannot be opened, we attempt the legacy macOS 12 pane URL:
    ///   `x-apple.systempreferences:com.apple.preference.notifications`
    /// - If that also fails, we fall back to opening general System Settings:
    ///   `x-apple.systempreferences:`
    public func openSystemSettingsForNotifications() {
        Self.logger.info("Opening System Settings for notifications.")

        let candidateURLs: [String] = [
            // macOS 13+ Notifications Settings extension pane
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
            // Legacy macOS 12 and earlier preference pane
            "x-apple.systempreferences:com.apple.preference.notifications",
            // Generic System Settings fallback
            "x-apple.systempreferences:"
        ]

        for urlString in candidateURLs {
            if let url = URL(string: urlString), NSWorkspace.shared.open(url) {
                Self.logger.info("Successfully opened settings via URL: \(urlString, privacy: .public)")
                return
            }
        }

        Self.logger.error("Failed to open System Settings via any candidate URL scheme.")
    }
}
