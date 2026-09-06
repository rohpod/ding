import Foundation
import os
import Sparkle

/// Service managing the Sparkle update framework lifecycle.
///
/// Follows the same `@MainActor`-isolated singleton pattern as `UpdateChecker` and `AppPreferences`
/// to guarantee thread safety across SwiftUI and AppKit components.
@MainActor
public final class SparkleUpdateManager {
    private static let logger = Logger(subsystem: DingLog.subsystem, category: "SparkleUpdateManager")

    /// The shared singleton instance of `SparkleUpdateManager`.
    public static let shared = SparkleUpdateManager()

    /// The underlying Sparkle standard updater controller.
    private var updaterController: SPUStandardUpdaterController?

    /// Exposes the active `SPUUpdater` instance for preference configuration and manual update triggers.
    public var updater: SPUUpdater? {
        updaterController?.updater
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
