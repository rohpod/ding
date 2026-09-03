import SwiftUI

/// Available tabs in the Ding Settings window.
enum SettingsTab: Hashable {
    case general
    case accounts
}

/// The root settings view displaying a horizontal tab-style layout for configuration.
struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
                .tag(SettingsTab.general)

            AccountsSettingsView()
                .tabItem {
                    Label("Accounts", systemImage: "at")
                }
                .tag(SettingsTab.accounts)
        }
        .tabViewStyle(.automatic)
        .frame(minWidth: 500, minHeight: 300)
    }
}
