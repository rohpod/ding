import XCTest
@testable import ding

final class AccountStoreTests: XCTestCase {
    private var tempDirectoryURL: URL!

    override func setUp() {
        super.setUp()
        tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ding-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let tempDirectoryURL = tempDirectoryURL {
            try? FileManager.default.removeItem(at: tempDirectoryURL)
        }
        super.tearDown()
    }

    func testLoadEmptyOrNonExistentFile() throws {
        let fileURL = tempDirectoryURL.appendingPathComponent("accounts.json")
        let store = AccountStore(fileURL: fileURL)

        // Non-existent file should return empty array without throwing
        let accounts = try store.load()
        XCTAssertTrue(accounts.isEmpty)
    }

    func testSaveAndLoadRoundTrip() throws {
        let fileURL = tempDirectoryURL.appendingPathComponent("accounts.json")
        let store = AccountStore(fileURL: fileURL)

        let account1 = Account(
            email: "user1@gmail.com",
            provider: .gmail,
            alias: "Main",
            syncFrequency: .always,
            notificationClickBehavior: .openMailApp
        )
        let account2 = Account(
            email: "user2@fastmail.com",
            provider: .fastmail,
            alias: "Backup",
            syncFrequency: .fiveMinutes,
            notificationClickBehavior: .openInBrowser
        )

        try store.save([account1, account2])

        // Verify file was written
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        // Load back and verify contents
        let loaded = try store.load()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0], account1)
        XCTAssertEqual(loaded[1], account2)
    }

    func testDirectoryAutoCreation() throws {
        // Deeply nested non-existent directory
        let deepDirectory = tempDirectoryURL
            .appendingPathComponent("Nested", isDirectory: true)
            .appendingPathComponent("SubDir", isDirectory: true)
        let fileURL = deepDirectory.appendingPathComponent("accounts.json")
        let store = AccountStore(fileURL: fileURL)

        let account = Account(email: "test@outlook.com", provider: .outlook)
        try store.save([account])

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let loaded = try store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].email, "test@outlook.com")
    }

    func testLoadCorruptedFileThrowsError() throws {
        let fileURL = tempDirectoryURL.appendingPathComponent("accounts.json")
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        try "not valid json".write(to: fileURL, atomically: true, encoding: .utf8)

        let store = AccountStore(fileURL: fileURL)

        XCTAssertThrowsError(try store.load()) { error in
            guard case AccountStoreError.decodingFailed = error else {
                XCTFail("Expected AccountStoreError.decodingFailed, got: \(error)")
                return
            }
        }
    }
}
