import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Global shortcut identifier for checking mail across all accounts.
    public static let checkAllMail = Self("checkAllMail")

    /// Per-account shortcut identifier for checking mail on a specific account.
    ///
    /// - Parameter accountID: The unique identifier of the target account.
    /// - Returns: A `KeyboardShortcuts.Name` keyed by account UUID string.
    public static func checkMail(accountID: UUID) -> Self {
        Self("checkMail_\(accountID.uuidString)")
    }
}
