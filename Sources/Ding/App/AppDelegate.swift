import AppKit
import os

/// The application delegate responsible for managing the menu bar status item and app lifecycle.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let logger = Logger(subsystem: "com.ding.mac", category: "AppLifecycle")

    /// The single system status bar item for Ding.
    private var statusItem: NSStatusItem?

    /// Controller for the settings window, preserved across openings and closings.
    private var settingsWindowController: SettingsWindowController?

    override init() {
        super.init()
        // Set activation policy as early as possible to prevent a Dock tile from appearing.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.logger.info("Ding launched. Ensuring accessory activation policy and setting up status bar item.")

        // Reinforce accessory activation policy for menu-bar-only operation.
        NSApplication.shared.setActivationPolicy(.accessory)

        setupStatusItem()

        // Per spec: BOTH first launch and subsequent launches should open the Settings window automatically.
        openSettings()
    }

    /// Configures the status bar item, its icon, and its drop-down menu.
    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = item.button {
            // TODO: replace with custom Ding icon asset
            button.image = NSImage(
                systemSymbolName: "envelope",
                accessibilityDescription: "Ding Mail Notification"
            )
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
            title: "Quit Ding",
            action: #selector(quitDing),
            keyEquivalent: "q"
        )
        quitMenuItem.target = self
        menu.addItem(quitMenuItem)

        item.menu = menu
        self.statusItem = item

        Self.logger.info("Menu bar status item configured successfully.")
    }

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

    /// Action handler for "Quit Ding".
    ///
    /// Terminates the application.
    @objc func quitDing() {
        Self.logger.info("Action triggered: quitDing")

        // NOTE: In later milestones, this must also cleanly cancel all SyncEngine
        // background tasks and active IMAP connections before terminating.

        NSApplication.shared.terminate(nil)
    }
}
