import AppKit
import os
import SwiftUI

/// The Accounts settings tab in Ding Settings.
///
/// Displays a split-view management interface:
/// - Left column: Vertical list of configured mail accounts with add/remove controls.
/// - Right panel: Editable configuration details for the currently selected account,
///   including re-authentication recovery, alias, sync frequency, and notification behavior.
@MainActor
struct AccountsSettingsView: View {
    private static let logger = Logger(subsystem: "com.ding.mac", category: "AccountsUI")

    @ObservedObject private var accountManager: AccountManager
    private let imapClientFactory: @Sendable (MailProvider) -> any IMAPConnecting

    @State private var selectedAccountID: UUID?
    @State private var isShowingAddAccountSheet: Bool = false
    @State private var isShowingDeleteConfirmation: Bool = false

    /// Initializes the accounts settings view.
    ///
    /// - Parameters:
    ///   - accountManager: The centralized account manager. Defaults to `AccountManager.shared`.
    ///   - imapClientFactory: Factory for creating IMAP clients during verification. Defaults to `NIOIMAPClient`.
    init(
        accountManager: AccountManager = .shared,
        imapClientFactory: @escaping @Sendable (MailProvider) -> any IMAPConnecting = { _ in NIOIMAPClient() }
    ) {
        self.accountManager = accountManager
        self.imapClientFactory = imapClientFactory
    }

    /// The currently selected `Account`, if any.
    private var selectedAccount: Account? {
        guard let id = selectedAccountID else { return nil }
        return accountManager.accounts.first { $0.id == id }
    }

    var body: some View {
        HStack(spacing: 0) {
            // MARK: - Left Column (Account List & Management)
            VStack(spacing: 0) {
                accountListView

                Divider()

                listToolbarView
            }
            .frame(width: 210)

            Divider()

            // MARK: - Right Panel (Account Detail / Empty State)
            Group {
                if let account = selectedAccount {
                    AccountDetailView(account: account, accountManager: accountManager)
                        .id(account.id)
                } else {
                    emptyStateView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            syncInitialSelection()
        }
        .onChange(of: accountManager.accounts) { newAccounts in
            syncSelectionAfterListUpdate(newAccounts: newAccounts)
        }
        .onChange(of: selectedAccountID) { _ in
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
        .sheet(isPresented: $isShowingAddAccountSheet) {
            AddAccountView(
                accountManager: accountManager,
                imapClientFactory: imapClientFactory
            )
        }
        .alert("Remove Account", isPresented: $isShowingDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Remove", role: .destructive) {
                handleRemoveSelectedAccount()
            }
        } message: {
            Text("Remove \"\(selectedAccount?.displayName ?? "this account")\"? This cannot be undone.")
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var accountListView: some View {
        if accountManager.accounts.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "tray")
                    .font(.title2)
                    .foregroundColor(.secondary)
                Text("No Accounts")
                    .font(.callout)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $selectedAccountID) {
                ForEach(accountManager.accounts) { account in
                    AccountListRow(account: account)
                        .tag(account.id)
                }
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private var listToolbarView: some View {
        HStack {
            HStack(spacing: 0) {
                Button {
                    isShowingAddAccountSheet = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .regular))
                        .frame(width: 30, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Add an account")

                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 1, height: 14)

                Button {
                    if selectedAccount != nil {
                        isShowingDeleteConfirmation = true
                    }
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 13, weight: .regular))
                        .frame(width: 30, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(selectedAccount == nil)
                .opacity(selectedAccount == nil ? 0.4 : 1.0)
                .help("Remove selected account")
            }
            .background(Color(nsColor: .controlColor))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var emptyStateView: some View {
        VStack(spacing: 10) {
            Image(systemName: "envelope.badge")
                .font(.system(size: 36))
                .foregroundColor(.secondary)

            Text(accountManager.accounts.isEmpty ? "No Accounts Configured" : "Select an Account")
                .font(.headline)
                .foregroundColor(.primary)

            Text(
                accountManager.accounts.isEmpty
                    ? "Click the \"+\" button to add a mail account."
                    : "Select an account from the list to view and configure its settings."
            )
            .font(.caption)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions & Helpers

    private func syncInitialSelection() {
        if selectedAccountID == nil {
            selectedAccountID = accountManager.accounts.first?.id
        }
    }

    private func syncSelectionAfterListUpdate(newAccounts: [Account]) {
        if let currentID = selectedAccountID {
            if !newAccounts.contains(where: { $0.id == currentID }) {
                selectedAccountID = newAccounts.first?.id
            }
        } else {
            selectedAccountID = newAccounts.first?.id
        }
    }

    private func handleRemoveSelectedAccount() {
        guard let account = selectedAccount else { return }
        Self.logger.info("Removing account \(account.id.uuidString, privacy: .public) (\(account.email, privacy: .public))")
        do {
            try accountManager.removeAccount(id: account.id)
        } catch {
            Self.logger.error("Failed to remove account \(account.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - Account List Row

/// Row component displaying an account in the left sidebar list.
private struct AccountListRow: View {
    let account: Account

    var body: some View {
        HStack(spacing: 8) {
            // Note: Provider-specific icons (e.g. Gmail, Outlook) can be added as image assets in a future release.
            Image(systemName: "envelope.circle")
                .font(.system(size: 16))
                .foregroundColor(.accentColor)

            Text(account.displayName)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            if account.needsReauthentication {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundColor(.red)
                    .font(.caption)
                    .help("Authentication failed — requires new App Password")
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Account Detail View

/// Right panel view displaying configuration fields for the selected account.
private struct AccountDetailView: View {
    private static let logger = Logger(subsystem: "com.ding.mac", category: "AccountsUI")

    let account: Account
    @ObservedObject var accountManager: AccountManager

    @State private var aliasText: String = ""
    @State private var newAppPassword: String = ""
    @State private var reauthErrorMessage: String?
    @State private var isUpdatingPassword: Bool = false
    @FocusState private var isAliasFocused: Bool

    var body: some View {
        Form {
            // MARK: - Re-authentication Callout Banner
            if account.needsReauthentication {
                Section {
                    reauthenticationBanner
                }
            }

            // MARK: - Account Details Section
            Section("Account Details") {
                LabeledContent("Email") {
                    Text(account.email)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }

                LabeledContent("Provider") {
                    Text(account.provider.displayName)
                        .foregroundColor(.secondary)
                }

                LabeledContent("Alias") {
                    TextField("", text: $aliasText)
                        .textFieldStyle(.roundedBorder)
                        .focused($isAliasFocused)
                        .onSubmit {
                            saveAlias()
                            isAliasFocused = false
                            NSApp.keyWindow?.makeFirstResponder(nil)
                        }
                        .onChange(of: aliasText) { _ in
                            saveAlias()
                        }
                        .onChange(of: isAliasFocused) { focused in
                            if !focused {
                                saveAlias()
                            }
                        }
                }
            }

            // MARK: - Settings Section
            Section("Preferences") {
                Picker("Sync frequency", selection: Binding(
                    get: { account.syncFrequency },
                    set: { newFrequency in
                        updateAccountSyncFrequency(newFrequency)
                    }
                )) {
                    ForEach(SyncFrequency.allCases, id: \.self) { freq in
                        Text(freq.displayName).tag(freq)
                    }
                }

                Picker("When notification is clicked", selection: Binding(
                    get: { account.notificationClickBehavior },
                    set: { newBehavior in
                        updateAccountClickBehavior(newBehavior)
                    }
                )) {
                    ForEach(NotificationClickBehavior.allCases, id: \.self) { behavior in
                        Text(behavior.displayName).tag(behavior)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .contentShape(Rectangle())
        .onTapGesture {
            if isAliasFocused {
                isAliasFocused = false
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
        .onExitCommand {
            if isAliasFocused {
                isAliasFocused = false
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
        .onAppear {
            aliasText = account.alias ?? ""
            newAppPassword = ""
            reauthErrorMessage = nil
        }
    }

    // MARK: - Re-authentication Banner

    @ViewBuilder
    private var reauthenticationBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Authentication failed — generate a new app password")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.red)

                    Text("The mail server rejected credentials for this account. Generate a new App Password and update it below.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Button {
                Self.logger.info("Opening app password URL for re-auth: \(self.account.provider.displayName, privacy: .public)")
                NSWorkspace.shared.open(account.provider.appPasswordURL)
            } label: {
                HStack(spacing: 4) {
                    Text("Get an app password for \(account.provider.displayName)")
                    Image(systemName: "arrow.up.right.square")
                }
                .font(.caption)
            }
            .buttonStyle(.link)

            HStack(spacing: 8) {
                SecureField("New App Password", text: $newAppPassword)
                    .textFieldStyle(.roundedBorder)

                Button("Update Password") {
                    handleUpdatePassword()
                }
                .disabled(newAppPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isUpdatingPassword)
            }

            if let error = reauthErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .padding(10)
        .background(Color.red.opacity(0.08))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.red.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Actions

    private func saveAlias() {
        let trimmed = aliasText.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalAlias = trimmed.isEmpty ? nil : trimmed
        if account.alias != finalAlias {
            var updated = account
            updated.alias = finalAlias
            do {
                try accountManager.updateAccount(updated)
                Self.logger.info("Updated alias for account \(self.account.id.uuidString, privacy: .public)")
            } catch {
                Self.logger.error("Failed to update alias: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func updateAccountSyncFrequency(_ newFrequency: SyncFrequency) {
        guard account.syncFrequency != newFrequency else { return }
        var updated = account
        updated.syncFrequency = newFrequency
        do {
            try accountManager.updateAccount(updated)
            Self.logger.info("Updated sync frequency for \(self.account.id.uuidString, privacy: .public) to \(newFrequency.rawValue, privacy: .public)")
        } catch {
            Self.logger.error("Failed to update sync frequency: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func updateAccountClickBehavior(_ newBehavior: NotificationClickBehavior) {
        guard account.notificationClickBehavior != newBehavior else { return }
        var updated = account
        updated.notificationClickBehavior = newBehavior
        do {
            try accountManager.updateAccount(updated)
            Self.logger.info("Updated notification click behavior for \(self.account.id.uuidString, privacy: .public) to \(newBehavior.rawValue, privacy: .public)")
        } catch {
            Self.logger.error("Failed to update notification click behavior: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handleUpdatePassword() {
        let cleaned = newAppPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }

        isUpdatingPassword = true
        reauthErrorMessage = nil

        do {
            try accountManager.updatePassword(forAccountID: account.id, newPassword: cleaned)
            var updated = account
            updated.needsReauthentication = false
            try accountManager.updateAccount(updated)

            newAppPassword = ""
            isUpdatingPassword = false
            Self.logger.info("Successfully updated password and cleared re-authentication requirement for \(self.account.id.uuidString, privacy: .public)")
        } catch {
            isUpdatingPassword = false
            reauthErrorMessage = error.localizedDescription
            Self.logger.error("Failed to update password for account \(self.account.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
