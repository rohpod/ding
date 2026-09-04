import AppKit
import os
import SwiftUI

/// Controls the lifecycle and presentation of the "ding Settings" window.
///
/// This controller hosts the SwiftUI `SettingsView` in an AppKit window.
/// It ensures that only a single instance of the window is created and that closing the window
/// hides it without quitting the application or releasing the window object.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private static let logger = Logger(subsystem: "com.ding.mac", category: "SettingsWindow")

    /// Initializes a new settings window controller hosting the SwiftUI `SettingsView`.
    init() {
        let contentRect = NSRect(x: 0, y: 0, width: 600, height: 400)
        let styleMask: NSWindow.StyleMask = [
            .titled,
            .closable,
            .miniaturizable,
            .resizable
        ]

        let window = NSWindow(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )

        window.title = "ding Settings"
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView())
        window.setFrameAutosaveName("dingSettingsWindow")

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Displays the settings window, bringing it to the foreground and activating the application.
    func showSettingsWindow() {
        guard let window = self.window else {
            Self.logger.error("Attempted to show settings window, but window was nil.")
            return
        }

        Self.logger.info("Opening settings window.")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - NSWindowDelegate

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            Self.logger.info("Settings window closed by user.")
        }
    }
}
