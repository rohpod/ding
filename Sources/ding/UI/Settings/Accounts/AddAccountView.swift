import AppKit
import os
import SwiftUI

/// Modal sheet for adding a new mail account to Ding with live IMAP verification.
///
/// ## Concurrency & Verification Flow
/// Account addition requires live credential verification using an implementation of `IMAPConnecting`
/// (defaulting to `NIOIMAPClient`). Under Swift 6 strict concurrency, operations are isolated to
/// `@MainActor`, safely awaiting asynchronous network calls on actor-isolated IMAP clients.
@MainActor
struct AddAccountView: View {
    private static let logger = Logger(subsystem: DingLog.subsystem, category: "AccountsUI")

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var accountManager: AccountManager

    /// Factory closure producing an `IMAPConnecting` instance for credential verification.
    /// Injected for hermetic unit testing without live network connections.
    private let imapClientFactory: @Sendable (MailProvider) -> any IMAPConnecting

    @State private var form = AddAccountFormState()
    @State private var alias: String = ""
    @State private var isVerifying: Bool = false
    @State private var errorMessage: String?

    /// Initializes a new Add Account modal view.
    ///
    /// - Parameters:
    ///   - accountManager: The centralized account manager. Defaults to `AccountManager.shared`.
    ///   - imapClientFactory: Factory for creating IMAP clients. Defaults to producing `NIOIMAPClient`.
    init(
        accountManager: AccountManager = .shared,
        imapClientFactory: @escaping @Sendable (MailProvider) -> any IMAPConnecting = { _ in NIOIMAPClient() }
    ) {
        self.accountManager = accountManager
        self.imapClientFactory = imapClientFactory
    }

    /// The provider in effect: the user's pick, or the one detected from the email.
    private var provider: MailProvider? {
        form.effectiveProvider
    }

    /// What the secret is called on screen.
    private var credentialLabel: String {
        provider == .custom ? "Password" : "App Password"
    }

    /// The picker's selection. Choosing is an explicit override that later email edits do not reset.
    private var providerSelection: Binding<MailProvider?> {
        Binding(
            get: { form.effectiveProvider },
            set: { form.providerOverride = $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // MARK: - Header
            Text("Add Account")
                .font(.headline)
                .padding(.bottom, 2)

            // MARK: - Email Field & Provider Detection
            VStack(alignment: .leading, spacing: 6) {
                Text("Email Address")
                    .font(.subheadline)
                    .fontWeight(.medium)

                TextField("name@example.com", text: $form.email)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isVerifying)

                if form.isCandidateEmailFormat {
                    Picker("Provider", selection: providerSelection) {
                        if provider == nil {
                            Text("Choose…").tag(MailProvider?.none)
                        }
                        ForEach(MailProvider.presets, id: \.self) { preset in
                            Text(preset.displayName).tag(MailProvider?.some(preset))
                        }
                        Text(MailProvider.custom.displayName).tag(MailProvider?.some(.custom))
                    }
                    .disabled(isVerifying)

                    if provider == nil {
                        Text("ding couldn't tell which provider this is. Choose one, or pick Other (IMAP) to enter a server. Using Google Workspace? Choose Gmail.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            // MARK: - Custom Server
            if provider == .custom {
                customServerFields
            }

            // MARK: - App Password Field & Instructions
            VStack(alignment: .leading, spacing: 6) {
                Text(credentialLabel)
                    .font(.subheadline)
                    .fontWeight(.medium)

                SecureField(credentialLabel, text: $form.password)
                    .textFieldStyle(.roundedBorder)
                    .disabled(provider == nil || isVerifying)
                    .opacity(provider == nil ? 0.5 : 1.0)

                if let provider, let portalURL = provider.appPasswordURL {
                    Button {
                        Self.logger.info("Opening app password portal for provider: \(provider.displayName, privacy: .public)")
                        NSWorkspace.shared.open(portalURL)
                    } label: {
                        HStack(spacing: 4) {
                            Text("Get an app password for \(provider.displayName)")
                            Image(systemName: "arrow.up.right.square")
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.link)
                    .disabled(isVerifying)

                    // Explanatory note regarding App Passwords
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Why an App Password?")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)

                        Text("An App Password is a unique passcode generated by your mail provider specifically for ding. Because modern accounts use two-factor authentication (2FA), standard account passwords cannot be used for direct IMAP login. You can revoke it independently at any time without changing your main password.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    )
                }
            }

            // MARK: - Optional Alias
            VStack(alignment: .leading, spacing: 6) {
                Text("Alias (Optional)")
                    .font(.subheadline)
                    .fontWeight(.medium)

                TextField("e.g. Work, Personal", text: $alias)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isVerifying)
            }

            // MARK: - Error Message Display
            if let error = errorMessage {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .font(.caption)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
            }

            Spacer(minLength: 4)

            // MARK: - Bottom Action Buttons
            HStack {
                Spacer()

                if isVerifying {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.trailing, 8)
                }

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isVerifying)

                Button("Continue") {
                    Task {
                        await verifyAndAddAccount()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!form.canContinue || isVerifying)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    /// Server, port and optional username for a provider that is not a preset.
    @ViewBuilder
    private var customServerFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Server")
                .font(.subheadline)
                .fontWeight(.medium)

            HStack(spacing: 8) {
                TextField("mail.example.com", text: $form.host)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isVerifying)

                TextField("993", text: $form.port)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)
                    .disabled(isVerifying)
            }

            if let message = form.serverValidationMessage {
                Text(message)
                    .font(.caption)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("IMAP over TLS (usually port 993) with a trusted certificate.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text("Username")
                .font(.subheadline)
                .fontWeight(.medium)
                .padding(.top, 4)

            TextField("Same as email", text: $form.username)
                .textFieldStyle(.roundedBorder)
                .disabled(isVerifying)
        }
    }

    // MARK: - Verification & Creation Logic

    private func verifyAndAddAccount() async {
        guard let provider, let server = form.server else {
            return
        }

        let cleanedEmail = form.email.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedPassword = form.password.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalAlias = Account.normalizeAlias(alias)

        isVerifying = true
        errorMessage = nil

        Self.logger.info("Initiating IMAP credential verification for provider \(provider.displayName, privacy: .public)")

        do {
            try await AccountVerifier.verify(
                client: imapClientFactory(provider),
                server: server,
                loginName: form.loginName,
                password: cleanedPassword
            )

            try accountManager.addAccount(
                email: cleanedEmail,
                provider: provider,
                appPassword: cleanedPassword,
                alias: finalAlias,
                customServer: provider == .custom ? server : nil,
                username: form.username
            )

            Self.logger.info("Account successfully verified and persisted for \(provider.displayName, privacy: .public)")
            isVerifying = false
            dismiss()
        } catch {
            isVerifying = false
            // The text can echo the user's server and login, so it is shown but not logged publicly.
            Self.logger.error("Account verification or creation failed: \(error.localizedDescription, privacy: .private)")
            errorMessage = AccountVerifier.message(for: error, provider: provider)
        }
    }
}
