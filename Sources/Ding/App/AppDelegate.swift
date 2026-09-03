import AppKit
import Combine
import os

/// The application delegate responsible for managing the menu bar status item and app lifecycle.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let logger = Logger(subsystem: "com.ding.mac", category: "AppLifecycle")

    /// The single system status bar item for ding, conditionally created based on user preference.
    private var statusItem: NSStatusItem?

    /// Controller for the settings window, preserved across openings and closings.
    private var settingsWindowController: SettingsWindowController?

    /// Combine subscriptions for observing preferences changes.
    private var cancellables = Set<AnyCancellable>()

    override init() {
        super.init()
        // Set activation policy as early as possible to prevent a Dock tile from appearing.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.logger.info("ding launched. Ensuring accessory activation policy and setting up status bar item.")

        // Reinforce accessory activation policy for menu-bar-only operation.
        NSApplication.shared.setActivationPolicy(.accessory)

        // Read isMenuBarIconVisible BEFORE creating the status item.
        // If false, skip initial creation to honor the persisted hidden-icon preference.
        if AppPreferences.shared.isMenuBarIconVisible {
            setupStatusItem()
        } else {
            Self.logger.info("Menu bar icon is disabled in user preferences; skipping initial status item creation.")
        }

        // Subscribe to live changes in isMenuBarIconVisible so toggling in Settings
        // immediately creates or removes the NSStatusItem without an app restart.
        observePreferences()

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
        Self.logger.info("ding reopen triggered from system (Spotlight/Applications). Opening Settings.")
        openSettings()
        return true
    }

    // MARK: - Preferences Observation

    /// Observes changes to `AppPreferences.isMenuBarIconVisible` and adjusts the status item dynamically.
    private func observePreferences() {
        AppPreferences.shared.$isMenuBarIconVisible
            .dropFirst() // Skip the initial value since applicationDidFinishLaunching already handled it
            .receive(on: RunLoop.main)
            .sink { [weak self] isVisible in
                self?.handleMenuBarIconVisibilityChange(isVisible)
            }
            .store(in: &cancellables)
    }

    /// Dynamically adds or removes the NSStatusItem in response to user preference changes.
    private func handleMenuBarIconVisibilityChange(_ isVisible: Bool) {
        if isVisible {
            if statusItem == nil {
                Self.logger.info("Menu bar icon preference enabled; creating status item.")
                setupStatusItem()
            }
        } else {
            if let item = statusItem {
                Self.logger.info("Menu bar icon preference disabled; removing status item from NSStatusBar.")
                NSStatusBar.system.removeStatusItem(item)
                self.statusItem = nil
            }
        }
    }

    // MARK: - Status Bar Item Setup

    /// Configures the status bar item, its icon, and its drop-down menu.
    private func setupStatusItem() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = item.button {
            // TODO: replace with custom ding icon asset
            let image = NSImage(
                systemSymbolName: "envelope",
                accessibilityDescription: "ding Mail Notification"
            )
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
        } else {
            Self.logger.error("Failed to access status item button.")
        }

        let menu = NSMenu()

        let settingsMenuItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsMenuItem.target = self
        menu.addItem(settingsMenuItem)

        menu.addItem(NSMenuItem.separator())

        let quitMenuItem = NSMenuItem(
            title: "Quit ding",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitMenuItem.target = self
        menu.addItem(quitMenuItem)

        item.menu = menu
        self.statusItem = item

        Self.logger.info("Menu bar status item configured successfully.")
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

    /// Action handler for "Quit ding".
    ///
    /// Terminates the application.
    @objc func quit() {
        Self.logger.info("Action triggered: quit")

        // NOTE: In later milestones, this must also cleanly cancel all SyncEngine
        // background tasks and active IMAP connections before terminating.

        NSApplication.shared.terminate(nil)
    }
}
