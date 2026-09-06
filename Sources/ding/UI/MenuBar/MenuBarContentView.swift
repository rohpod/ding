import SwiftUI

/// SwiftUI view providing the drop-down menu items for ding's menu bar status item.
struct MenuBarContentView: View {
    @ObservedObject private var syncEngine = SyncEngine.shared

    var body: some View {
        Button("Check for Mail") {
            Task {
                await syncEngine.checkAllMail()
            }
        }

        ForEach(syncEngine.manualCheckAccounts) { account in
            Button(account.displayName) {
                Task {
                    await syncEngine.checkMail(accountID: account.id)
                }
            }
        }

        Divider()

        Button("Check for Updates…") {
            SparkleUpdateManager.shared.checkForUpdates()
        }

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
