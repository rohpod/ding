import SwiftUI

/// SwiftUI view providing the drop-down menu items for ding's menu bar status item.
struct MenuBarContentView: View {
    var body: some View {
        Button("Settings…") {
            AppDelegate.shared?.openSettings()
        }
        .keyboardShortcut(",")

        Divider()

        Button("Quit ding") {
            AppDelegate.shared?.quit()
        }
        .keyboardShortcut("q")
    }
}
