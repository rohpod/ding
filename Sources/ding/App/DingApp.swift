import SwiftUI

/// The main application entry point for ding.
///
/// ## Architecture Note: `NSStatusItem` vs `MenuBarExtra`
/// ding deliberately uses a manual `NSStatusItem` hosted via `AppDelegate` rather than SwiftUI's `MenuBarExtra` scene.
/// While `MenuBarExtra` is available in macOS 13+, `NSStatusItem` provides:
/// 1. Deterministic control over menu behavior and AppKit activation policy (`.accessory`).
/// 2. Seamless dynamic icon swapping and animated status states (needed in later milestones for sync/unread badges).
/// 3. Precise window management without spurious scene-lifecycle windows being spawned on launch.
@main
struct dingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        if CommandLine.arguments.contains("--reset-login-item") {
            try? LoginItemManager.shared.disableLoginItem()
            exit(0)
        }
    }

    var body: some Scene {
        // An empty Settings scene satisfies SwiftUI's requirement for a root Scene
        // while preventing SwiftUI from automatically spawning a default WindowGroup on launch.
        // The Settings window is managed explicitly via AppKit and SettingsWindowController.
        Settings {
            EmptyView()
        }
    }
}
