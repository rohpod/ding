import XCTest
@testable import ding

final class AccountTests: XCTestCase {
    func testAccountDefaults() {
        let account = Account(
            email: "test@gmail.com",
            provider: .gmail
        )

        XCTAssertFalse(account.id.uuidString.isEmpty)
        XCTAssertEqual(account.email, "test@gmail.com")
        XCTAssertEqual(account.provider, .gmail)
        XCTAssertNil(account.alias)
        XCTAssertEqual(account.syncFrequency, .useDefault)
        XCTAssertEqual(account.notificationClickBehavior, .useDefault)
        XCTAssertLessThanOrEqual(account.dateAdded, Date())
    }

    func testAccountDisplayName() {
        // Alias present and non-empty
        let withAlias = Account(
            email: "user@example.com",
            provider: .icloud,
            alias: "Personal"
        )
        XCTAssertEqual(withAlias.displayName, "Personal")

        // Alias nil falls back to email
        let withoutAlias = Account(
            email: "user@example.com",
            provider: .icloud,
            alias: nil
        )
        XCTAssertEqual(withoutAlias.displayName, "user@example.com")

        // Alias whitespace-only falls back to email
        let whitespaceAlias = Account(
            email: "user@example.com",
            provider: .icloud,
            alias: "   \n"
        )
        XCTAssertEqual(whitespaceAlias.displayName, "user@example.com")
    }

    func testAccountCodableRoundTripAndSecretExclusion() throws {
        let original = Account(
            id: UUID(),
            email: "alice@outlook.com",
            provider: .outlook,
            alias: "Work Mail",
            syncFrequency: .fifteenMinutes,
            notificationClickBehavior: .openMailApp,
            dateAdded: Date(timeIntervalSince1970: 1700000000)
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        // Verify JSON string contains all metadata but NO password key
        let jsonString = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(jsonString.contains("alice@outlook.com"))
        XCTAssertTrue(jsonString.contains("Work Mail"))
        XCTAssertFalse(jsonString.contains("password"))
        XCTAssertFalse(jsonString.contains("appPassword"))
        XCTAssertFalse(jsonString.contains("secret"))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Account.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.email, original.email)
        XCTAssertEqual(decoded.provider, original.provider)
        XCTAssertEqual(decoded.alias, original.alias)
        XCTAssertEqual(decoded.syncFrequency, original.syncFrequency)
        XCTAssertEqual(decoded.notificationClickBehavior, original.notificationClickBehavior)
    }

    func testAccountEquatable() {
        let id = UUID()
        let date = Date()
        let a1 = Account(id: id, email: "test@yahoo.com", provider: .yahoo, alias: "Yahoo", syncFrequency: .hourly, notificationClickBehavior: .doNothing, dateAdded: date)
        let a2 = Account(id: id, email: "test@yahoo.com", provider: .yahoo, alias: "Yahoo", syncFrequency: .hourly, notificationClickBehavior: .doNothing, dateAdded: date)
        let a3 = Account(id: UUID(), email: "test@yahoo.com", provider: .yahoo, alias: "Yahoo", syncFrequency: .hourly, notificationClickBehavior: .doNothing, dateAdded: date)

        XCTAssertEqual(a1, a2)
        XCTAssertNotEqual(a1, a3)
    }
}
