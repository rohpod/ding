import Foundation

/// The values and rules behind the Add Account sheet, kept out of the view so they can be tested.
struct AddAccountFormState: Equatable {
    var email: String = ""
    var password: String = ""

    /// The provider the user picked explicitly. Survives edits to `email`; `nil` means "follow detection".
    var providerOverride: MailProvider?

    var host: String = ""
    var port: String = "993"
    var username: String = ""

    /// The explicit pick if any, otherwise the preset matching the email's domain.
    var effectiveProvider: MailProvider? {
        providerOverride ?? MailProvider.detect(fromEmail: email)
    }

    /// Whether the email looks like an address (one `@` with text on both sides).
    var isCandidateEmailFormat: Bool {
        let parts = email.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty
    }

    /// Why the typed server is not acceptable, or `nil` if it is fine or the host has not been typed yet.
    var serverValidationMessage: String? {
        guard effectiveProvider == .custom, !host.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        do {
            _ = try IMAPServer.validated(host: host, port: port)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// The server to verify and store: the validated entry for `.custom`, otherwise the provider's preset.
    var server: IMAPServer? {
        guard let provider = effectiveProvider else { return nil }
        if provider == .custom {
            return try? IMAPServer.validated(host: host, port: port)
        }
        return provider.presetServer
    }

    /// The name to log in with: the username for a custom server when given, otherwise the email.
    var loginName: String {
        let cleanedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard effectiveProvider == .custom else { return cleanedEmail }
        return Account.normalizeUsername(username, email: cleanedEmail) ?? cleanedEmail
    }

    /// Whether the form is complete enough to start verification (the caller also checks that none is running).
    var canContinue: Bool {
        isCandidateEmailFormat
            && server != nil
            && !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
