import Foundation

/// Represents an event emitted when new mail is detected in an account's inbox.
///
/// ## Milestone 7 Notification Integration Boundary
/// `NewMailEvent` encapsulates all metadata required to present system notifications via
/// `UNUserNotificationCenter` in Milestone 7 without requiring additional network queries.
/// It bundles the target `accountID` alongside the array of freshly detected `MessageSummary` objects.
public struct NewMailEvent: Sendable, Equatable {
    /// The unique identifier of the account where new mail was detected.
    public let accountID: UUID

    /// The collection of new messages detected since the last synchronization pass.
    public let messages: [MessageSummary]

    /// Initializes a new mail event.
    ///
    /// - Parameters:
    ///   - accountID: The identifier of the account.
    ///   - messages: The new messages detected.
    public init(accountID: UUID, messages: [MessageSummary]) {
        self.accountID = accountID
        self.messages = messages
    }
}
