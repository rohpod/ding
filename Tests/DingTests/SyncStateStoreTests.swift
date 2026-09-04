import XCTest
@testable import ding

final class SyncStateStoreTests: XCTestCase {
    private var temporaryDirectoryURL: URL!
    private var testFileURL: URL!

    override func setUp() {
        super.setUp()
        temporaryDirectoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        testFileURL = temporaryDirectoryURL.appendingPathComponent("test_sync_state.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        super.tearDown()
    }

    func testLoadFromNonExistentFileReturnsEmpty() throws {
        let store = SyncStateStore(fileURL: testFileURL)
        let states = try store.load()
        XCTAssertTrue(states.isEmpty)
    }

    func testSaveAndLoadRoundTrip() throws {
        let store = SyncStateStore(fileURL: testFileURL)
        let accountID1 = UUID()
        let accountID2 = UUID()

        let state1 = SyncState(
            accountID: accountID1,
            uidValidity: 12345,
            lastSeenUID: 100,
            lastSyncedAt: Date()
        )
        let state2 = SyncState(
            accountID: accountID2,
            uidValidity: 67890,
            lastSeenUID: 250,
            lastSyncedAt: Date().addingTimeInterval(-3600)
        )

        try store.save([state1, state2])

        let loaded = try store.load()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0], state1)
        XCTAssertEqual(loaded[1], state2)
    }

    func testStateForAccountID() throws {
        let store = SyncStateStore(fileURL: testFileURL)
        let targetID = UUID()
        let otherID = UUID()

        let targetState = SyncState(
            accountID: targetID,
            uidValidity: 111,
            lastSeenUID: 50,
            lastSyncedAt: Date()
        )
        let otherState = SyncState(
            accountID: otherID,
            uidValidity: 222,
            lastSeenUID: 75,
            lastSyncedAt: Date()
        )

        try store.save([targetState, otherState])

        let found = try store.state(forAccountID: targetID)
        XCTAssertNotNil(found)
        XCTAssertEqual(found, targetState)

        let notFound = try store.state(forAccountID: UUID())
        XCTAssertNil(notFound)
    }

    func testUpdateStateUpsert() throws {
        let store = SyncStateStore(fileURL: testFileURL)
        let accountID = UUID()

        // 1. Insert new state via updateState
        let initial = SyncState(
            accountID: accountID,
            uidValidity: 100,
            lastSeenUID: 1,
            lastSyncedAt: Date()
        )
        try store.updateState(initial)

        var loaded = try store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first, initial)

        // 2. Update existing state
        let updated = SyncState(
            accountID: accountID,
            uidValidity: 100,
            lastSeenUID: 42,
            lastSyncedAt: Date().addingTimeInterval(60)
        )
        try store.updateState(updated)

        loaded = try store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.lastSeenUID, 42)
    }
}
