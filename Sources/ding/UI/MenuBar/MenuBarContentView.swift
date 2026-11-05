import SwiftUI

/// SwiftUI view providing the drop-down menu items for ding's menu bar status item.
struct MenuBarContentView: View {
    @ObservedObject private var syncEngine = SyncEngine.shared

    var body: some View {
        if !syncEngine.accountsNeedingAttention.isEmpty {
            ForEach(syncEngine.accountsNeedingAttention) { account in
                Button("⚠︎ \(account.displayName) needs a new \(account.credentialName)…") {
                    AppDelegate.shared?.openSettings()
                }
            }

            Divider()
        }

        if !syncEngine.accountsWithConnectionProblems.isEmpty {
            ForEach(syncEngine.accountsWithConnectionProblems) { account in
                Button("⚠︎ \(account.displayName) can't connect…") {
                    AppDelegate.shared?.openSettings()
                }
            }

            Divider()
        }

        if !syncEngine.isNetworkAvailable && !syncEngine.allAccounts.isEmpty {
            Text("Offline")

            Divider()
        }

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

        if !syncEngine.allAccounts.isEmpty {
            Menu("Account Status") {
                ForEach(syncEngine.allAccounts) { account in
                    Text("\(account.displayName): \(statusSummary(for: account))")
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

    private func statusSummary(for account: Account) -> String {
        AccountHealthFormatter.summary(
            account: account,
            health: syncEngine.accountHealth[account.id],
            isNetworkAvailable: syncEngine.isNetworkAvailable
        )
    }
}
