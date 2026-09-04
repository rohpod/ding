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

    func testAccountNeedsReauthenticationDefaultAndMutation() {
        var account = Account(email: "bob@fastmail.com", provider: .fastmail)
        XCTAssertFalse(account.needsReauthentication)

        account.needsReauthentication = true
        XCTAssertTrue(account.needsReauthentication)
    }

    func testAccountCodableBackwardsCompatibilityWithoutNeedsReauthenticationKey() throws {
        // Milestone 3 JSON payload without 'needsReauthentication'
        let legacyJSON = """
        {
            "id": "E621E1F8-C36C-495A-93FC-0C247A3E6E5F",
            "email": "legacy@gmail.com",
            "provider": "gmail",
            "alias": "Old Account",
            "syncFrequency": "fifteenMinutes",
            "notificationClickBehavior": "openMailApp",
            "dateAdded": "2026-09-01T00:00:00Z"
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Account.self, from: Data(legacyJSON.utf8))

        XCTAssertEqual(decoded.email, "legacy@gmail.com")
        XCTAssertEqual(decoded.provider, .gmail)
        XCTAssertEqual(decoded.alias, "Old Account")
        XCTAssertEqual(decoded.syncFrequency, .fifteenMinutes)
        XCTAssertEqual(decoded.notificationClickBehavior, .openMailApp)
        XCTAssertFalse(decoded.needsReauthentication)
    }

    func testAccountCodableWithNeedsReauthenticationTrue() throws {
        let account = Account(
            id: UUID(),
            email: "reauth@outlook.com",
            provider: .outlook,
            needsReauthentication: true
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(account)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Account.self, from: data)

        XCTAssertTrue(decoded.needsReauthentication)
        XCTAssertEqual(decoded, account)
    }

    @MainActor
    func testAccountEffectiveSyncFrequencyOverridesGeneralDefault() {
        let suiteName = "com.ding.tests.syncfreq.\(UUID().uuidString)"
        guard let testDefaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create test defaults.")
            return
        }
        defer { testDefaults.removePersistentDomain(forName: suiteName) }

        // Set global default to hourly
        AppPreferences.shared.defaultSyncFrequency = .hourly

        // Account with .useDefault resolves to global setting (.hourly)
        var account = Account(email: "test@gmail.com", provider: .gmail, syncFrequency: .useDefault)
        XCTAssertEqual(account.effectiveSyncFrequency, .hourly)

        // Setting a specific sync frequency on the account explicitly overrides the global default
        account.syncFrequency = .fiveMinutes
        XCTAssertEqual(account.effectiveSyncFrequency, .fiveMinutes, "Account-specific frequency should override general setting")

        // Changing global setting later does not change this account's overridden frequency
        AppPreferences.shared.defaultSyncFrequency = .thirtyMinutes
        XCTAssertEqual(account.effectiveSyncFrequency, .fiveMinutes, "Account override should remain independent of global changes")

        // Reset global setting back to default
        AppPreferences.shared.defaultSyncFrequency = .always
    }

    @MainActor
    func testAccountEffectiveNotificationClickBehaviorOverridesGeneralDefault() {
        // Set global default to openMailApp
        AppPreferences.shared.defaultNotificationClickBehavior = .openMailApp

        // Account with .useDefault resolves to global setting (.openMailApp)
        var account = Account(email: "test@gmail.com", provider: .gmail, notificationClickBehavior: .useDefault)
        XCTAssertEqual(account.effectiveNotificationClickBehavior, .openMailApp)

        // Setting a specific click behavior on the account explicitly overrides the global default
        account.notificationClickBehavior = .openInBrowser
        XCTAssertEqual(account.effectiveNotificationClickBehavior, .openInBrowser, "Account-specific behavior should override general setting")

        // Reset global setting back to default
        AppPreferences.shared.defaultNotificationClickBehavior = .doNothing
    }

    func testAccountEquatable() {
        let id = UUID()
        let date = Date()
        let a1 = Account(id: id, email: "test@yahoo.com", provider: .yahoo, alias: "Yahoo", syncFrequency: .hourly, notificationClickBehavior: .doNothing, dateAdded: date)
        let a2 = Account(id: id, email: "test@yahoo.com", provider: .yahoo, alias: "Yahoo", syncFrequency: .hourly, notificationClickBehavior: .doNothing, dateAdded: date)
        let a3 = Account(id: UUID(), email: "test@yahoo.com", provider: .yahoo, alias: "Yahoo", syncFrequency: .hourly, notificationClickBehavior: .doNothing, dateAdded: date)
        let a4 = Account(id: id, email: "test@yahoo.com", provider: .yahoo, alias: "Yahoo", syncFrequency: .hourly, notificationClickBehavior: .doNothing, needsReauthentication: true, dateAdded: date)

        XCTAssertEqual(a1, a2)
        XCTAssertNotEqual(a1, a3)
        XCTAssertNotEqual(a1, a4)
    }
}
