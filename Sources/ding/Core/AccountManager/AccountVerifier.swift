import Foundation

/// Proves that an account's credentials and server really work, before they are stored.
///
/// Shared by the Add Account sheet and the password-update banner so both apply the same standard. `SELECT INBOX`
/// is part of it because a successful login alone does not mean the sync loop will work: `selectInbox` throws when
/// a server omits `UIDVALIDITY`, and it is better to say so in the sheet than to fail silently later.
enum AccountVerifier {
    /// Connects, logs in and selects the inbox, always disconnecting afterwards, including on failure.
    static func verify(
        client: any IMAPConnecting,
        server: IMAPServer,
        loginName: String,
        password: String
    ) async throws {
        do {
            try await client.connect(host: server.host, port: server.port)
            try await client.login(email: loginName, password: password)
            _ = try await client.selectInbox()
            await client.disconnect()
        } catch {
            await client.disconnect()
            throw error
        }
    }

    /// The text shown to the user for a failed verification.
    ///
    /// A TLS failure on a custom server is usually a wrong name or port, or a certificate ding refuses to trust,
    /// so it gets a hint the generic error text lacks.
    static func message(for error: Error, provider: MailProvider) -> String {
        let base = error.localizedDescription
        if provider == .custom, case IMAPClientError.tlsHandshakeFailed = error {
            return base + " Check the server name and port. ding needs a TLS connection (usually port 993) with a trusted certificate."
        }
        return base
    }
}
