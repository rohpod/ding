import XCTest
import UserNotifications
@testable import ding

final class dingTests: XCTestCase {
    // MARK: - SyncFrequency Tests

    func testSyncFrequencyDisplayNamesAndIntervals() {
        XCTAssertEqual(SyncFrequency.useDefault.displayName, "Default")
        XCTAssertNil(SyncFrequency.useDefault.intervalSeconds, "useDefault delegates to global setting, interval should be nil.")

        XCTAssertEqual(SyncFrequency.always.displayName, "Always")
        XCTAssertNil(SyncFrequency.always.intervalSeconds, "Always mode is IMAP IDLE push-based, interval should be nil.")

        XCTAssertEqual(SyncFrequency.oneMinute.displayName, "Every 1 minute")
        XCTAssertEqual(SyncFrequency.oneMinute.intervalSeconds, 60.0)

        XCTAssertEqual(SyncFrequency.fiveMinutes.displayName, "Every 5 minutes")
        XCTAssertEqual(SyncFrequency.fiveMinutes.intervalSeconds, 300.0)

        XCTAssertEqual(SyncFrequency.fifteenMinutes.displayName, "Every 15 minutes")
        XCTAssertEqual(SyncFrequency.fifteenMinutes.intervalSeconds, 900.0)

        XCTAssertEqual(SyncFrequency.thirtyMinutes.displayName, "Every 30 minutes")
        XCTAssertEqual(SyncFrequency.thirtyMinutes.intervalSeconds, 1800.0)

        XCTAssertEqual(SyncFrequency.hourly.displayName, "Hourly")
        XCTAssertEqual(SyncFrequency.hourly.intervalSeconds, 3600.0)
    }

    func testSyncFrequencyCodable() throws {
        for frequency in SyncFrequency.allCases {
            let encoded = try JSONEncoder().encode(frequency)
            let decoded = try JSONDecoder().decode(SyncFrequency.self, from: encoded)
            XCTAssertEqual(decoded, frequency)
        }
    }

    // MARK: - NotificationClickBehavior Tests

    func testNotificationClickBehaviorDisplayNames() {
        XCTAssertEqual(NotificationClickBehavior.useDefault.displayName, "Default")
        XCTAssertEqual(NotificationClickBehavior.doNothing.displayName, "Do nothing")
        XCTAssertEqual(NotificationClickBehavior.openMailApp.displayName, "Open Mail app")
        XCTAssertEqual(NotificationClickBehavior.openInBrowser.displayName, "Open in browser")
    }

    func testNotificationClickBehaviorCodable() throws {
        for behavior in NotificationClickBehavior.allCases {
            let encoded = try JSONEncoder().encode(behavior)
            let decoded = try JSONDecoder().decode(NotificationClickBehavior.self, from: encoded)
            XCTAssertEqual(decoded, behavior)
        }
    }

    // MARK: - AppPreferences Tests

    @MainActor
    func testAppPreferencesDefaults() {
        // Use an isolated UserDefaults suite name
        let suiteName = "com.ding.tests.preferences.\(UUID().uuidString)"
        guard let testDefaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated test UserDefaults suite.")
            return
        }
        defer { testDefaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppPreferences(userDefaults: testDefaults)

        XCTAssertEqual(preferences.defaultSyncFrequency, .always)
        XCTAssertEqual(preferences.defaultNotificationClickBehavior, .doNothing)
        XCTAssertTrue(preferences.isMenuBarIconVisible)
        XCTAssertFalse(preferences.isOpenAtLoginEnabled)
    }

    @MainActor
    func testAppPreferencesPersistence() {
        let suiteName = "com.ding.tests.persistence.\(UUID().uuidString)"
        guard let testDefaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated test UserDefaults suite.")
            return
        }
        defer { testDefaults.removePersistentDomain(forName: suiteName) }

        // Set custom values in preferences
        let preferences = AppPreferences(userDefaults: testDefaults)
        preferences.defaultSyncFrequency = .fifteenMinutes
        preferences.defaultNotificationClickBehavior = .openMailApp
        preferences.isMenuBarIconVisible = false
        preferences.isOpenAtLoginEnabled = true

        // Create a second preferences instance pointing to the same storage to verify persistence
        let reloaded = AppPreferences(userDefaults: testDefaults)
        XCTAssertEqual(reloaded.defaultSyncFrequency, .fifteenMinutes)
        XCTAssertEqual(reloaded.defaultNotificationClickBehavior, .openMailApp)
        XCTAssertFalse(reloaded.isMenuBarIconVisible)
        XCTAssertTrue(reloaded.isOpenAtLoginEnabled)
    }

    // MARK: - Core Services Verification

    @MainActor
    func testNotificationPermissionManagerQuery() async {
        // Test default instance in CLI/test unbundled environment
        let manager = NotificationPermissionManager()
        let defaultStatus = await manager.currentAuthorizationStatus()
        XCTAssertEqual(defaultStatus, .notDetermined)

        // Test mock provider instance
        let mockManager = NotificationPermissionManager(statusProvider: { .authorized })
        let mockStatus = await mockManager.currentAuthorizationStatus()
        XCTAssertEqual(mockStatus, .authorized)
    }

    @MainActor
    func testNotificationPermissionManagerRequest() async throws {
        // Test mock requester
        let grantedManager = NotificationPermissionManager(authorizationRequester: { true })
        let granted = try await grantedManager.requestAuthorization()
        XCTAssertTrue(granted)

        // Test unbundled error handling
        let unbundledManager = NotificationPermissionManager()
        do {
            _ = try await unbundledManager.requestAuthorization()
            XCTFail("Expected NotificationError.requiresAppBundle when unbundled")
        } catch let error as NotificationError {
            XCTAssertEqual(error, .requiresAppBundle)
            XCTAssertNotNil(error.errorDescription)
        }
    }

    @MainActor
    func testLoginItemManagerStatusQuery() {
        let manager = LoginItemManager()
        // In unbundled test environment, isLoginItemEnabled should safely return false without throwing
        XCTAssertFalse(manager.isLoginItemEnabled)
        XCTAssertEqual(manager.status, .notRegistered)
    }

    @MainActor
    func testLoginItemManagerUnbundledError() {
        let manager = LoginItemManager()
        XCTAssertThrowsError(try manager.enableLoginItem()) { error in
            guard let loginError = error as? LoginItemError else {
                XCTFail("Expected LoginItemError.requiresAppBundle, got \(error)")
                return
            }
            XCTAssertEqual(loginError, .requiresAppBundle)
            XCTAssertNotNil(loginError.errorDescription)
        }
    }
}
