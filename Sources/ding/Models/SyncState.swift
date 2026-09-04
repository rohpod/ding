import Foundation

/// Represents the persisted synchronization state for an individual mail account.
///
/// ## RFC 3501 UIDVALIDITY Semantics & Historical Notification Prevention
/// In the IMAP protocol (RFC 3501 Section 2.3.1.1), each mailbox has a 32-bit unsigned `UIDVALIDITY` value.
/// Message Unique Identifiers (UIDs) are assigned in strictly ascending order within a mailbox session,
/// but are only guaranteed to be stable and unique as long as the mailbox `UIDVALIDITY` does not change.
///
/// If a mail server rebuilds its index, restores from backup, or renames/recreates a mailbox, the server
/// MUST report a different `UIDVALIDITY` value upon the next `SELECT` command. When `uidValidity` changes:
/// - All previously stored `lastSeenUID` values for that mailbox become obsolete and invalid.
/// - A message that had UID 500 under the old validity might now have UID 12, or UID 500 might correspond to a completely different email.
/// - The client cannot assume any continuity with previously observed message identifiers.
///
/// ### Ding's Reset Strategy
/// Rather than resetting `lastSeenUID` to `0` (which would cause the sync engine to re-fetch and fire duplicate macOS
/// notifications for hundreds or thousands of old historical messages in the user's inbox), Ding handles a `UIDVALIDITY`
/// change by resetting `lastSeenUID` to the mailbox's current baseline (`uidNext - 1`, or `0` if empty).
/// This safely establishes a fresh tracking boundary so that Ding only emits notifications for genuine new mail
/// arriving from that moment forward.
public struct SyncState: Identifiable, Codable, Equatable, Sendable {
    /// The stable identifier matching `Account.id`.
    public let accountID: UUID

    /// The mailbox unique identifier validity value (`UIDVALIDITY`) associated with `lastSeenUID`.
    public var uidValidity: UInt32

    /// The highest message UID that has been fetched and processed for new-mail detection.
    public var lastSeenUID: UInt32

    /// The timestamp when synchronization was last successfully executed.
    public var lastSyncedAt: Date

    public var id: UUID { accountID }

    private enum CodingKeys: String, CodingKey {
        case accountID
        case uidValidity
        case lastSeenUID
        case lastSyncedAt
    }

    /// Initializes a new sync state tracking instance.
    ///
    /// - Parameters:
    ///   - accountID: The unique account identifier.
    ///   - uidValidity: The mailbox's `UIDVALIDITY` value.
    ///   - lastSeenUID: The highest UID observed.
    ///   - lastSyncedAt: The timestamp of the sync pass. Defaults to current date.
    public init(
        accountID: UUID,
        uidValidity: UInt32,
        lastSeenUID: UInt32,
        lastSyncedAt: Date = Date()
    ) {
        self.accountID = accountID
        self.uidValidity = uidValidity
        self.lastSeenUID = lastSeenUID
        // Floor to whole seconds so date equality survives ISO-8601 round-tripping without sub-second skew
        self.lastSyncedAt = Date(timeIntervalSince1970: floor(lastSyncedAt.timeIntervalSince1970))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.accountID = try container.decode(UUID.self, forKey: .accountID)
        self.uidValidity = try container.decode(UInt32.self, forKey: .uidValidity)
        self.lastSeenUID = try container.decode(UInt32.self, forKey: .lastSeenUID)
        self.lastSyncedAt = try container.decode(Date.self, forKey: .lastSyncedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accountID, forKey: .accountID)
        try container.encode(uidValidity, forKey: .uidValidity)
        try container.encode(lastSeenUID, forKey: .lastSeenUID)
        try container.encode(lastSyncedAt, forKey: .lastSyncedAt)
    }

    public static func == (lhs: SyncState, rhs: SyncState) -> Bool {
        lhs.accountID == rhs.accountID &&
        lhs.uidValidity == rhs.uidValidity &&
        lhs.lastSeenUID == rhs.lastSeenUID &&
        abs(lhs.lastSyncedAt.timeIntervalSince(rhs.lastSyncedAt)) < 1.0
    }
}
