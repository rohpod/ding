import XCTest
import Security
@testable import ding

/// In-memory implementation of `KeychainServiceProtocol` for isolated, hermetic unit testing.
final class InMemoryKeychainService: KeychainServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UUID: String] = [:]
    private var retrieveCallCount: [UUID: Int] = [:]
    var errorToThrowOnRetrieve: (any Error)?

    func retrieveCalls(forAccountID id: UUID) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return retrieveCallCount[id, default: 0]
    }

    func store(password: String, forAccountID id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        if storage[id] != nil {
            throw KeychainError.duplicateItem
        }
        storage[id] = password
    }

    func retrievePassword(forAccountID id: UUID) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        retrieveCallCount[id, default: 0] += 1

        if let error = errorToThrowOnRetrieve {
            throw error
        }

        guard let password = storage[id] else {
            throw KeychainError.itemNotFound
        }
        return password
    }

    func updatePassword(_ password: String, forAccountID id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[id] = password
    }

    func deletePassword(forAccountID id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        guard storage.removeValue(forKey: id) != nil else {
            throw KeychainError.itemNotFound
        }
    }
}

final class KeychainServiceTests: XCTestCase {
    // MARK: - In-Memory Keychain Protocol Tests

    func testInMemoryKeychainStoreAndRetrieve() throws {
        let service = InMemoryKeychainService()
        let id = UUID()

        try service.store(password: "secret-token-123", forAccountID: id)
        let retrieved = try service.retrievePassword(forAccountID: id)
        XCTAssertEqual(retrieved, "secret-token-123")
    }

    func testInMemoryKeychainDuplicateStoreThrows() throws {
        let service = InMemoryKeychainService()
        let id = UUID()

        try service.store(password: "initial", forAccountID: id)
        XCTAssertThrowsError(try service.store(password: "duplicate", forAccountID: id)) { error in
            XCTAssertEqual(error as? KeychainError, .duplicateItem)
        }
    }

    func testInMemoryKeychainRetrieveNotFoundThrows() {
        let service = InMemoryKeychainService()
        let id = UUID()

        XCTAssertThrowsError(try service.retrievePassword(forAccountID: id)) { error in
            XCTAssertEqual(error as? KeychainError, .itemNotFound)
        }
    }

    func testInMemoryKeychainUpdateExistingAndNonExistent() throws {
        let service = InMemoryKeychainService()
        let id = UUID()

        // Upsert non-existent
        try service.updatePassword("first-pass", forAccountID: id)
        XCTAssertEqual(try service.retrievePassword(forAccountID: id), "first-pass")

        // Update existing
        try service.updatePassword("updated-pass", forAccountID: id)
        XCTAssertEqual(try service.retrievePassword(forAccountID: id), "updated-pass")
    }

    func testInMemoryKeychainDelete() throws {
        let service = InMemoryKeychainService()
        let id = UUID()

        try service.store(password: "to-delete", forAccountID: id)
        try service.deletePassword(forAccountID: id)

        XCTAssertThrowsError(try service.retrievePassword(forAccountID: id)) { error in
            XCTAssertEqual(error as? KeychainError, .itemNotFound)
        }

        // Deleting non-existent throws
        XCTAssertThrowsError(try service.deletePassword(forAccountID: id)) { error in
            XCTAssertEqual(error as? KeychainError, .itemNotFound)
        }
    }

    // MARK: - Real System Keychain Tests

    func testSystemKeychainLiveRoundTripIfPermitted() {
        let testServiceName = "com.ding.mac.v2.tests.\(UUID().uuidString)"
        let service = KeychainService(serviceName: testServiceName)
        let id = UUID()

        do {
            try service.store(password: "system-test-pass", forAccountID: id)
            defer {
                try? service.deletePassword(forAccountID: id)
            }

            let retrieved = try service.retrievePassword(forAccountID: id)
            XCTAssertEqual(retrieved, "system-test-pass")

            try service.updatePassword("new-system-pass", forAccountID: id)
            let updated = try service.retrievePassword(forAccountID: id)
            XCTAssertEqual(updated, "new-system-pass")

            try service.deletePassword(forAccountID: id)
            XCTAssertThrowsError(try service.retrievePassword(forAccountID: id)) { error in
                XCTAssertEqual(error as? KeychainError, .itemNotFound)
            }
        } catch let error as KeychainError {
            switch error {
            case .unhandledStatus(let status) where status == errSecInteractionNotAllowed || status == -34018 || status == -60005:
                // Expected when running in headless CI / unbundled sandboxed test runner without interactive keychain
                break
            default:
                XCTFail("Unexpected Keychain error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testKeychainErrorAccessDeniedOrCancelledDescriptions() {
        let error = KeychainError.accessDeniedOrCancelled
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("denied or cancelled"))
        XCTAssertEqual(error, .accessDeniedOrCancelled)
        XCTAssertNotEqual(error, .itemNotFound)
    }

    func testInMemoryKeychainRetrieveAccessDeniedThrows() {
        let service = InMemoryKeychainService()
        let id = UUID()
        service.errorToThrowOnRetrieve = KeychainError.accessDeniedOrCancelled

        XCTAssertThrowsError(try service.retrievePassword(forAccountID: id)) { error in
            XCTAssertEqual(error as? KeychainError, .accessDeniedOrCancelled)
        }
    }

    func testLegacyServiceItemIsMigratedForwardOnRetrieve() {
        let legacyName = "com.ding.mac.v2.tests.\(UUID().uuidString)"
        let currentName = "com.ding.mac.v3.tests.\(UUID().uuidString)"
        let legacy = KeychainService(serviceName: legacyName, legacyServiceNames: [])
        let current = KeychainService(serviceName: currentName, legacyServiceNames: [legacyName])
        let id = UUID()

        do {
            try legacy.store(password: "old-release-password", forAccountID: id)
            defer {
                try? legacy.deletePassword(forAccountID: id)
                try? current.deletePassword(forAccountID: id)
            }

            XCTAssertEqual(try current.retrievePassword(forAccountID: id), "old-release-password")

            // The item now lives under the current name and the legacy copy is gone.
            let currentOnly = KeychainService(serviceName: currentName, legacyServiceNames: [])
            XCTAssertEqual(try currentOnly.retrievePassword(forAccountID: id), "old-release-password")
            XCTAssertThrowsError(try legacy.retrievePassword(forAccountID: id)) { error in
                XCTAssertEqual(error as? KeychainError, .itemNotFound)
            }
        } catch let error as KeychainError {
            switch error {
            case .unhandledStatus(let status) where status == errSecInteractionNotAllowed || status == -34018 || status == -60005:
                break // headless runner without an interactive keychain
            default:
                XCTFail("Unexpected Keychain error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMissingItemEverywhereStillReportsItemNotFound() {
        let service = KeychainService(
            serviceName: "com.ding.mac.v3.tests.\(UUID().uuidString)",
            legacyServiceNames: ["com.ding.mac.v2.tests.\(UUID().uuidString)"]
        )
        XCTAssertThrowsError(try service.retrievePassword(forAccountID: UUID())) { error in
            if let keychainError = error as? KeychainError, case .unhandledStatus = keychainError { return } // headless
            XCTAssertEqual(error as? KeychainError, .itemNotFound)
        }
    }
}
