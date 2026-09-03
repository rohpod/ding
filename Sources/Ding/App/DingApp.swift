import SwiftUI

/// The main application entry point for Ding.
///
/// ## Architecture Note: `NSStatusItem` vs `MenuBarExtra`
/// Ding deliberately uses a manual `NSStatusItem` hosted via `AppDelegate` rather than SwiftUI's `MenuBarExtra` scene.
/// While `MenuBarExtra` is available in macOS 13+, `NSStatusItem` provides:
/// 1. Deterministic control over menu behavior and AppKit activation policy (`.accessory`).
/// 2. Seamless dynamic icon swapping and animated status states (needed in later milestones for sync/unread badges).
/// 3. Precise window management without spurious scene-lifecycle windows being spawned on launch.
@main
struct DingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // An empty Settings scene satisfies SwiftUI's requirement for a root Scene
        // while preventing SwiftUI from automatically spawning a default WindowGroup on launch.
        // The Settings window is managed explicitly via AppKit and SettingsWindowController.
        Settings {
            EmptyView()
        }
    }
}
