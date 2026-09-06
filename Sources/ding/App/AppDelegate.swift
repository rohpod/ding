import AppKit
import Combine
import os
import UserNotifications

/// The application delegate responsible for managing app lifecycle, background tasks, and notifications.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let logger = Logger(subsystem: DingLog.subsystem, category: "AppLifecycle")

    /// Shared singleton instance accessible by views and controllers.
    public static private(set) var shared: AppDelegate?

    /// Strong reference to the notification click and presentation delegate.
    private let notificationClickHandler = NotificationClickHandler.shared

    /// Service responsible for delivering notifications and requesting permission.
    private let notificationService = NotificationService.shared

    /// Active background task consuming the aggregated new mail event stream.
    private var mailStreamTask: Task<Void, Never>?

    /// Low-priority background task managing periodic automatic update checks.
    private var updateCheckTask: Task<Void, Never>?

    /// Controller for the settings window, preserved across openings and closings.
    private var settingsWindowController: SettingsWindowController?

    /// Combine subscriptions for observing preferences changes.
    private var cancellables = Set<AnyCancellable>()

    override init() {
        super.init()
        AppDelegate.shared = self
        // Set activation policy as early as possible to prevent a Dock tile from appearing.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.logger.info("ding launched. Ensuring accessory activation policy.")

        // Configure UNUserNotificationCenter delegate early in launch sequence before any notifications arrive.
        if NotificationPermissionManager.isRunningInAppBundle {
            UNUserNotificationCenter.current().delegate = notificationClickHandler
        }

        // Reinforce accessory activation policy for menu-bar-only operation.
        NSApplication.shared.setActivationPolicy(.accessory)

        // Start Sparkle updater framework if running in an app bundle
        SparkleUpdateManager.shared.startIfNeeded()

        // Subscribe to live changes in preferences
        observePreferences()

        // Start SyncEngine to begin watching all configured accounts
        SyncEngine.shared.start()

        // Subscribe to aggregated new mail events
        startObservingNewMail()

        // Schedule silent background update checking if enabled
        scheduleAutomaticUpdateChecks()

        // Request notification permission if not yet determined
        Task {
            await notificationService.requestPermissionIfNeeded()
        }

        // Per spec: BOTH first launch and subsequent launches should open the Settings window automatically.
        // This ensures the user has immediate access to configuration even if the menu bar icon is hidden.
        openSettings()
    }

    /// Handles application reopen events (e.g. launching ding from Applications or Spotlight while already running).
    ///
    /// Relaunching the app must ALWAYS reopen the Settings window regardless of whether the menu bar
    /// icon is visible or hidden. This allows users who have hidden the menu bar icon to easily access
    /// settings by launching ding again from Applications or Spotlight.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // If the app was reopened because the user clicked a notification,
        // do not pop open the settings window.
        // We dispatch asynchronously so any concurrent notification event updates lastNotificationClickTime.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let timeSinceClick = Date().timeIntervalSince(NotificationClickHandler.lastNotificationClickTime)
            if timeSinceClick < 0.5 {
                Self.logger.info("Reopen event associated with notification click; skipping Settings window presentation.")
                return
            }
            Self.logger.info("ding reopen triggered from system (Spotlight/Applications). Opening Settings.")
            self.openSettings()
        }
        return true
    }

    /// Observes changes to `AppPreferences` and reacts dynamically.
    private func observePreferences() {
        AppPreferences.shared.$isAutomaticUpdateCheckEnabled
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] isEnabled in
                self?.handleAutomaticUpdateCheckPreferenceChange(isEnabled)
            }
            .store(in: &cancellables)

        AppPreferences.shared.$isAutomaticUpdateInstallEnabled
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] isEnabled in
                self?.handleAutomaticUpdateInstallPreferenceChange(isEnabled)
            }
            .store(in: &cancellables)
    }

    // MARK: - Actions

    /// Action handler for "Settings…".
    ///
    /// Opens the settings window or brings it to the front if it is already open.
    @objc func openSettings() {
        Self.logger.info("Action triggered: openSettings")
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }

        guard let controller = settingsWindowController else {
            Self.logger.error("Failed to initialize SettingsWindowController.")
            return
        }

        controller.showSettingsWindow()
    }

    // MARK: - New Mail Observation

    /// Subscribes to the aggregated stream of new mail events emitted across all account workers.
    private func startObservingNewMail() {
        mailStreamTask?.cancel()
        let stream = SyncEngine.shared.newMailStream()
        mailStreamTask = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { break }
                await self?.handleNewMailEvent(event)
            }
        }
    }

    /// Handles an incoming new mail event by looking up the account and posting a notification.
    private func handleNewMailEvent(_ event: NewMailEvent) async {
        guard let account = AccountManager.shared.accounts.first(where: { $0.id == event.accountID }) else {
            Self.logger.warning("Received new mail event for account \(event.accountID.uuidString, privacy: .public), but account is no longer registered.")
            return
        }

        await notificationService.send(for: event, account: account)
    }

    // MARK: - Automatic Update Checking

    /// Configures and starts the low-priority background task for automatic periodic update checks.
    private func scheduleAutomaticUpdateChecks() {
        updateCheckTask?.cancel()
        guard AppPreferences.shared.isAutomaticUpdateCheckEnabled else {
            Self.logger.info("Automatic update checking is disabled; skipping scheduler.")
            return
        }

        updateCheckTask = Task {
            // Wait briefly after app launch before checking to keep launch lightweight.
            try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
            guard !Task.isCancelled else { return }

            let checkInterval: TimeInterval = 24 * 60 * 60 // 24 hours

            // Check shortly after launch if 24 hours have elapsed since the last check
            let shouldCheckNow: Bool
            if let lastDate = AppPreferences.shared.lastUpdateCheckDate {
                shouldCheckNow = Date().timeIntervalSince(lastDate) >= checkInterval
            } else {
                shouldCheckNow = true
            }

            if shouldCheckNow {
                Self.logger.info("Performing initial background update check...")
                _ = await UpdateChecker.shared.checkForUpdate()
            }

            // Periodic background check loop (every 24 hours)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(checkInterval) * 1_000_000_000)
                guard !Task.isCancelled else { break }
                guard AppPreferences.shared.isAutomaticUpdateCheckEnabled else { break }

                Self.logger.info("Performing periodic 24-hour background update check...")
                _ = await UpdateChecker.shared.checkForUpdate()
            }
        }
    }

    /// Handles dynamic toggling of the automatic update checking preference.
    private func handleAutomaticUpdateCheckPreferenceChange(_ isEnabled: Bool) {
        SparkleUpdateManager.shared.applyPreferences(AppPreferences.shared)

        if isEnabled {
            Self.logger.info("Automatic update checking enabled in preferences; starting scheduler.")
            scheduleAutomaticUpdateChecks()
        } else {
            Self.logger.info("Automatic update checking disabled in preferences; cancelling background task.")
            updateCheckTask?.cancel()
            updateCheckTask = nil
        }
    }

    /// Handles dynamic toggling of the automatic update installation preference.
    private func handleAutomaticUpdateInstallPreferenceChange(_ isEnabled: Bool) {
        Self.logger.info("Automatic update install preference changed (\(isEnabled, privacy: .public)); syncing with Sparkle.")
        SparkleUpdateManager.shared.applyPreferences(AppPreferences.shared)
    }

    /// Action handler for "Quit ding".
    ///
    /// Terminates the application.
    @objc func quit() {
        Self.logger.info("Action triggered: quit")

        // Cancel the background update check task
        updateCheckTask?.cancel()
        updateCheckTask = nil

        // Cancel the mail stream consumer task
        mailStreamTask?.cancel()
        mailStreamTask = nil

        // Cleanly cancel all SyncEngine background tasks and active IMAP connections before terminating.
        SyncEngine.shared.stop()

        NSApplication.shared.terminate(nil)
    }
}
