import AppKit
import Foundation
import os
import Sparkle

/// Service managing the Sparkle update framework lifecycle.
///
/// Follows the same `@MainActor`-isolated singleton pattern as `AppPreferences`
/// to guarantee thread safety across SwiftUI and AppKit components.
@MainActor
public final class SparkleUpdateManager: ObservableObject {
    private static let logger = Logger(subsystem: DingLog.subsystem, category: "SparkleUpdateManager")

    /// The shared singleton instance of `SparkleUpdateManager`.
    public static let shared = SparkleUpdateManager()

    /// The underlying Sparkle standard updater controller.
    private var updaterController: SPUStandardUpdaterController?

    /// Exposes the active `SPUUpdater` instance for preference configuration and manual update triggers.
    public var updater: SPUUpdater? {
        updaterController?.updater
    }

    /// Indicates whether the updater is initialized and currently capable of checking for updates.
    public var canCheckForUpdates: Bool {
        updater?.canCheckForUpdates ?? false
    }

    /// Initializes a new `SparkleUpdateManager`.
    private init() {}

    /// Initializes and starts the Sparkle updater controller if executing within a macOS application bundle.
    ///
    /// Running outside a valid `.app` bundle (e.g. during CLI development or unit test execution)
    /// will cause Sparkle initialization to assert or fail. This method guards against non-bundle
    /// execution environments before instantiating `SPUStandardUpdaterController`.
    public func startIfNeeded() {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            Self.logger.info("Running outside of an .app bundle; skipping Sparkle updater initialization.")
            return
        }

        guard updaterController == nil else {
            Self.logger.debug("Sparkle updater controller already initialized.")
            return
        }

        Self.logger.info("Initializing SPUStandardUpdaterController...")
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        Self.logger.info("SPUStandardUpdaterController initialized successfully.")
        applyPreferences(AppPreferences.shared)
    }

    /// Initiates a manual update check.
    ///
    /// Activates the application so that the Sparkle update check window surfaces
    /// cleanly above other windows even in a menu-bar accessory (`LSUIElement`) app.
    public func checkForUpdates() {
        guard let controller = updaterController else {
            Self.logger.info("Cannot check for updates: Sparkle updater controller is not initialized (running outside .app bundle).")
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    /// Applies user preferences to the live Sparkle updater instance.
    ///
    /// - Parameter preferences: The active `AppPreferences` store.
    public func applyPreferences(_ preferences: AppPreferences) {
        guard let updater = self.updater else {
            Self.logger.debug("Cannot apply preferences: Sparkle updater is not initialized.")
            return
        }

        updater.automaticallyChecksForUpdates = preferences.isAutomaticUpdateCheckEnabled
        updater.automaticallyDownloadsUpdates = preferences.isAutomaticUpdateInstallEnabled

        Self.logger.info("Applied update preferences to Sparkle (autoCheck: \(preferences.isAutomaticUpdateCheckEnabled, privacy: .public), autoInstall: \(preferences.isAutomaticUpdateInstallEnabled, privacy: .public))")
    }
}
