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
    private static let logger = Logger(subsystem: "com.ding.mac", category: "AccountsUI")

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var accountManager: AccountManager

    /// Factory closure producing an `IMAPConnecting` instance for credential verification.
    /// Injected for hermetic unit testing without live network connections.
    private let imapClientFactory: @Sendable (MailProvider) -> any IMAPConnecting

    @State private var email: String = ""
    @State private var appPassword: String = ""
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

    /// The mail provider detected from the current email input.
    private var detectedProvider: MailProvider? {
        MailProvider.detect(fromEmail: email)
    }

    /// Determines whether the email format looks like a candidate address (contains @ and a domain).
    private var isCandidateEmailFormat: Bool {
        let cleaned = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = cleaned.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty
    }

    /// Determines whether the "Continue" action can be executed.
    private var canContinue: Bool {
        detectedProvider != nil &&
            !appPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !isVerifying
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

                TextField("name@example.com", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isVerifying)

                if let provider = detectedProvider {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                        Text("Provider: \(provider.displayName)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else if isCandidateEmailFormat {
                    Text("Unsupported provider. Ding currently supports Gmail, iCloud, Outlook, Yahoo, and Fastmail.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // MARK: - App Password Field & Instructions
            VStack(alignment: .leading, spacing: 6) {
                Text("App Password")
                    .font(.subheadline)
                    .fontWeight(.medium)

                SecureField("App Password", text: $appPassword)
                    .textFieldStyle(.roundedBorder)
                    .disabled(detectedProvider == nil || isVerifying)
                    .opacity(detectedProvider == nil ? 0.5 : 1.0)

                if let provider = detectedProvider {
                    Button {
                        Self.logger.info("Opening app password portal for provider: \(provider.displayName, privacy: .public)")
                        NSWorkspace.shared.open(provider.appPasswordURL)
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

                        Text("An App Password is a unique passcode generated by your mail provider specifically for Ding. Because modern accounts use two-factor authentication (2FA), standard account passwords cannot be used for direct IMAP login. You can revoke it independently at any time without changing your main password.")
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
                .disabled(!canContinue)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    // MARK: - Verification & Creation Logic

    private func verifyAndAddAccount() async {
        guard let provider = detectedProvider else {
            return
        }

        let cleanedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedPassword = appPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalAlias = trimmedAlias.isEmpty ? nil : trimmedAlias

        isVerifying = true
        errorMessage = nil

        Self.logger.info("Initiating IMAP credential verification for provider \(provider.displayName, privacy: .public)")

        let client = imapClientFactory(provider)
        do {
            try await client.connect(host: provider.imapHost, port: provider.imapPort)
            try await client.login(email: cleanedEmail, password: cleanedPassword)
            await client.disconnect()

            try accountManager.addAccount(
                email: cleanedEmail,
                provider: provider,
                appPassword: cleanedPassword,
                alias: finalAlias
            )

            Self.logger.info("Account successfully verified and persisted for \(provider.displayName, privacy: .public)")
            isVerifying = false
            dismiss()
        } catch let error as IMAPClientError {
            await client.disconnect()
            isVerifying = false
            Self.logger.error("IMAP client verification failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = message(for: error, provider: provider)
        } catch let error as AccountManagerError {
            await client.disconnect()
            isVerifying = false
            Self.logger.error("AccountManager error after verification: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        } catch {
            await client.disconnect()
            isVerifying = false
            Self.logger.error("Unexpected error during account addition: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    private func message(for error: IMAPClientError, provider: MailProvider) -> String {
        switch error {
        case .authenticationFailed:
            return "Incorrect app password — check you copied it correctly, or generate a new one."
        case .connectionFailed:
            return "Couldn't connect to \(provider.imapHost) — check your internet connection and try again."
        case .timeout:
            return "The connection timed out while contacting \(provider.displayName). Please try again."
        case .tlsHandshakeFailed:
            return "Secure connection failed — unable to establish TLS with \(provider.imapHost)."
        case .unexpectedResponse(let details):
            return "Unexpected response from \(provider.displayName): \(details)"
        case .notConnected:
            return "Not connected to the mail server."
        }
    }
}
