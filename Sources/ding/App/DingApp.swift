import SwiftUI

/// The main application entry point for ding.
///
/// ## Architecture Note: Migration to `MenuBarExtra`
/// ding previously managed a manual `NSStatusItem` hosted via `AppDelegate`.
/// The app was migrated to SwiftUI's `MenuBarExtra` scene because the manual `NSStatusItem`
/// setup failed to display an icon when launched from a signed `.build/ding.app` bundle,
/// and `MenuBarExtra` eliminates custom status item lifecycle management code.
@main
struct dingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var preferences = AppPreferences.shared
    @State private var isMenuBarIconVisible: Bool = AppPreferences.shared.isMenuBarIconVisible

    init() {
        if CommandLine.arguments.contains("--reset-login-item") {
            try? LoginItemManager.shared.disableLoginItem()
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra(isInserted: $isMenuBarIconVisible) {
            MenuBarContentView()
        } label: {
            Image(nsImage: MenuBarIconLoader.loadMenuBarIcon())
        }
        .menuBarExtraStyle(.menu)
        .onChange(of: isMenuBarIconVisible) { newValue in
            if AppPreferences.shared.isMenuBarIconVisible != newValue {
                AppPreferences.shared.isMenuBarIconVisible = newValue
            }
        }
        .onChange(of: preferences.isMenuBarIconVisible) { newValue in
            if isMenuBarIconVisible != newValue {
                isMenuBarIconVisible = newValue
            }
        }
    }
}
