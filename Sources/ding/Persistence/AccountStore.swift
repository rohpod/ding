import Foundation
import os

/// Errors encountered during account file persistence.
public enum AccountStoreError: LocalizedError, Sendable {
    /// Failed to create the Application Support directory.
    case directoryCreationFailed(Error)

    /// Failed to encode account list into JSON.
    case encodingFailed(Error)

    /// Failed to decode account list from JSON.
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
            return "Failed to encode accounts to JSON: \(error.localizedDescription)"
        case .decodingFailed(let error):
            return "Failed to decode accounts from JSON: \(error.localizedDescription)"
        case .writeFailed(let error):
            return "Failed to write accounts file to disk: \(error.localizedDescription)"
        case .readFailed(let error):
            return "Failed to read accounts file from disk: \(error.localizedDescription)"
        }
    }
}

/// Protocol defining disk persistence operations for mail accounts.
public protocol AccountStoreProtocol: Sendable {
    /// Reads and decodes persisted accounts from disk.
    ///
    /// - Returns: An array of `Account` instances, or an empty array if the store does not yet exist.
    /// - Throws: `AccountStoreError` if file reading or decoding fails.
    func load() throws -> [Account]

    /// Encodes and writes accounts to disk atomically.
    ///
    /// - Parameter accounts: The list of `Account` models to persist.
    /// - Throws: `AccountStoreError` if directory creation, encoding, or writing fails.
    func save(_ accounts: [Account]) throws
}

/// Manages serialization and deserialization of account models to `accounts.json`
/// in the user's Application Support directory.
///
/// ## Security Separation
/// Per Ding's security model, this store writes metadata only. Passwords are never
/// serialized to this file and reside exclusively in the system Keychain.
public final class AccountStore: AccountStoreProtocol, Sendable {
    private static let logger = Logger(subsystem: "com.ding.mac", category: "AccountStore")

    /// The resolved URL of the accounts JSON file.
    public let fileURL: URL

    /// Default URL pointing to `~/Library/Application Support/Ding/accounts.json`.
    public static var defaultFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: ("~/Library/Application Support" as NSString).expandingTildeInPath)
        return appSupport.appendingPathComponent("Ding", isDirectory: true).appendingPathComponent("accounts.json")
    }

    /// Initializes an account disk store.
    ///
    /// - Parameter fileURL: The JSON file URL to read and write. Defaults to `defaultFileURL`.
    public init(fileURL: URL = AccountStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    /// Loads accounts from disk.
    ///
    /// If the file does not yet exist (such as on a fresh installation), an empty array is returned.
    public func load() throws -> [Account] {
        let path = fileURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            Self.logger.info("No existing accounts file found at \(path, privacy: .public); returning empty accounts list.")
            return []
        }

        Self.logger.debug("Reading accounts file from \(path, privacy: .public)")
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            Self.logger.error("Failed to read accounts file: \(error.localizedDescription, privacy: .public)")
            throw AccountStoreError.readFailed(error)
        }

        // Return empty array if file is zero bytes
        guard !data.isEmpty else {
            return []
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let accounts = try decoder.decode([Account].self, from: data)
            Self.logger.info("Successfully loaded \(accounts.count) accounts from disk.")
            return accounts
        } catch {
            Self.logger.error("Failed to decode accounts JSON: \(error.localizedDescription, privacy: .public)")
            throw AccountStoreError.decodingFailed(error)
        }
    }

    /// Saves accounts to disk atomically.
    ///
    /// Automatically ensures the enclosing directory exists prior to saving.
    public func save(_ accounts: [Account]) throws {
        let parentDirectory = fileURL.deletingLastPathComponent()

        do {
            try FileManager.default.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
        } catch {
            Self.logger.error("Failed to create storage directory at \(parentDirectory.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw AccountStoreError.directoryCreationFailed(error)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data: Data
        do {
            data = try encoder.encode(accounts)
        } catch {
            Self.logger.error("Failed to encode accounts: \(error.localizedDescription, privacy: .public)")
            throw AccountStoreError.encodingFailed(error)
        }

        do {
            try data.write(to: fileURL, options: .atomic)
            Self.logger.info("Successfully persisted \(accounts.count) accounts to \(self.fileURL.path, privacy: .public)")
        } catch {
            Self.logger.error("Failed to write accounts file: \(error.localizedDescription, privacy: .public)")
            throw AccountStoreError.writeFailed(error)
        }
    }
}
