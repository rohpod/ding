import Foundation
import os

/// Errors encountered during sync state file persistence.
public enum SyncStateStoreError: LocalizedError, Sendable {
    /// Failed to create the Application Support directory.
    case directoryCreationFailed(Error)

    /// Failed to encode sync states into JSON.
    case encodingFailed(Error)

    /// Failed to decode sync states from JSON.
    case decodingFailed(Error)

    /// Failed to write JSON data to disk.
    case writeFailed(Error)

    /// Failed to read JSON data from disk.
    case readFailed(Error)

    public var errorDescription: String? {
        switch self {
        case .directoryCreationFailed(let error):
            return "Failed to create Application Support storage directory: \(error.localizedDescription)"
        case .encodingFailed(let error):
            return "Failed to encode sync state to JSON: \(error.localizedDescription)"
        case .decodingFailed(let error):
            return "Failed to decode sync state from JSON: \(error.localizedDescription)"
        case .writeFailed(let error):
            return "Failed to write sync state file to disk: \(error.localizedDescription)"
        case .readFailed(let error):
            return "Failed to read sync state file from disk: \(error.localizedDescription)"
        }
    }
}

/// Protocol defining disk persistence operations for account synchronization state.
public protocol SyncStateStoreProtocol: Sendable {
    /// Reads and decodes persisted sync states from disk.
    ///
    /// - Returns: An array of `SyncState` instances, or an empty array if the store does not yet exist.
    /// - Throws: `SyncStateStoreError` if file reading or decoding fails.
    func load() throws -> [SyncState]

    /// Encodes and writes sync states to disk atomically.
    ///
    /// - Parameter states: The list of `SyncState` models to persist.
    /// - Throws: `SyncStateStoreError` if directory creation, encoding, or writing fails.
    func save(_ states: [SyncState]) throws

    /// Convenience lookup for an individual account's persisted sync state.
    ///
    /// - Parameter id: The account UUID to search for.
    /// - Returns: The existing `SyncState` if found; `nil` otherwise.
    func state(forAccountID id: UUID) throws -> SyncState?

    /// Inserts or updates the persisted sync state for a single account.
    ///
    /// - Parameter state: The new or updated `SyncState`.
    func updateState(_ state: SyncState) throws
}

/// Manages serialization and deserialization of account sync states to `sync_state.json`
/// in the user's Application Support directory.
public final class SyncStateStore: SyncStateStoreProtocol, Sendable {
    private static let logger = Logger(subsystem: "com.ding.mac", category: "SyncStateStore")

    /// The resolved URL of the sync state JSON file.
    public let fileURL: URL

    /// Default URL pointing to `~/Library/Application Support/Ding/sync_state.json`.
    public static var defaultFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: ("~/Library/Application Support" as NSString).expandingTildeInPath)
        return appSupport.appendingPathComponent("Ding", isDirectory: true).appendingPathComponent("sync_state.json")
    }

    /// Initializes a sync state disk store.
    ///
    /// - Parameter fileURL: The JSON file URL to read and write. Defaults to `defaultFileURL`.
    public init(fileURL: URL = SyncStateStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    /// Loads sync states from disk.
    ///
    /// If the file does not yet exist (such as on a fresh installation), an empty array is returned.
    public func load() throws -> [SyncState] {
        let path = fileURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            Self.logger.info("No existing sync state file found at \(path, privacy: .public); returning empty list.")
            return []
        }

        Self.logger.debug("Reading sync state file from \(path, privacy: .public)")
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            Self.logger.error("Failed to read sync state file: \(error.localizedDescription, privacy: .public)")
            throw SyncStateStoreError.readFailed(error)
        }

        guard !data.isEmpty else {
            return []
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let states = try decoder.decode([SyncState].self, from: data)
            Self.logger.info("Successfully loaded \(states.count) sync states from disk.")
            return states
        } catch {
            Self.logger.error("Failed to decode sync states JSON: \(error.localizedDescription, privacy: .public)")
            throw SyncStateStoreError.decodingFailed(error)
        }
    }

    /// Saves sync states to disk atomically.
    public func save(_ states: [SyncState]) throws {
        let parentDirectory = fileURL.deletingLastPathComponent()

        do {
            try FileManager.default.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
        } catch {
            Self.logger.error("Failed to create storage directory at \(parentDirectory.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw SyncStateStoreError.directoryCreationFailed(error)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data: Data
        do {
            data = try encoder.encode(states)
        } catch {
            Self.logger.error("Failed to encode sync states: \(error.localizedDescription, privacy: .public)")
            throw SyncStateStoreError.encodingFailed(error)
        }

        do {
            try data.write(to: fileURL, options: .atomic)
            Self.logger.info("Successfully persisted \(states.count) sync states to \(self.fileURL.path, privacy: .public)")
        } catch {
            Self.logger.error("Failed to write sync state file: \(error.localizedDescription, privacy: .public)")
            throw SyncStateStoreError.writeFailed(error)
        }
    }

    /// Convenience lookup for an individual account's persisted sync state.
    public func state(forAccountID id: UUID) throws -> SyncState? {
        let states = try load()
        return states.first(where: { $0.accountID == id })
    }

    /// Inserts or updates the persisted sync state for a single account.
    public func updateState(_ state: SyncState) throws {
        var states = try load()
        if let index = states.firstIndex(where: { $0.accountID == state.accountID }) {
            states[index] = state
        } else {
            states.append(state)
        }
        try save(states)
    }
}
