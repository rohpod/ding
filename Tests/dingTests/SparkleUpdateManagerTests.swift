import XCTest
@testable import ding

@MainActor
final class SparkleUpdateManagerTests: XCTestCase {

    func testSafeBehaviorOutsideAppBundleContext() {
        let manager = SparkleUpdateManager.shared

        // In test environment, the process runs outside of a .app bundle
        manager.startIfNeeded()

        // Verify updater is not initialized and checks cannot be performed
        XCTAssertFalse(manager.canCheckForUpdates, "canCheckForUpdates must be false when running outside a .app bundle")
        XCTAssertNil(manager.updater, "updater should be nil outside a .app bundle")

        // Calling checkForUpdates should safely handle nil updaterController without crashing
        manager.checkForUpdates()
    }

    func testPreferenceForwardingHandlesNilUpdater() {
        let suiteName = "com.ding.tests.sparkle.preferences.\(UUID().uuidString)"
        guard let testDefaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated test UserDefaults suite.")
            return
        }
        defer { testDefaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppPreferences(userDefaults: testDefaults)
        preferences.isAutomaticUpdateCheckEnabled = false
        preferences.isAutomaticUpdateInstallEnabled = true

        let manager = SparkleUpdateManager.shared

        // Applying preferences when updater is nil outside .app bundle must not crash
        manager.applyPreferences(preferences)
    }

    func testBothTogglePreferencesPersistence() {
        let suiteName = "com.ding.tests.sparkle.toggles.\(UUID().uuidString)"
        guard let testDefaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated test UserDefaults suite.")
            return
        }
        defer { testDefaults.removePersistentDomain(forName: suiteName) }

        // Test default values
        let preferences = AppPreferences(userDefaults: testDefaults)
        XCTAssertTrue(preferences.isAutomaticUpdateCheckEnabled, "Default automatic update check must be true")
        XCTAssertFalse(preferences.isAutomaticUpdateInstallEnabled, "Default automatic update install must be false")

        // Mutate both toggles
        preferences.isAutomaticUpdateCheckEnabled = false
        preferences.isAutomaticUpdateInstallEnabled = true

        // Verify persistence with a new instance
        let reloaded = AppPreferences(userDefaults: testDefaults)
        XCTAssertFalse(reloaded.isAutomaticUpdateCheckEnabled, "isAutomaticUpdateCheckEnabled should persist false")
        XCTAssertTrue(reloaded.isAutomaticUpdateInstallEnabled, "isAutomaticUpdateInstallEnabled should persist true")

        // Toggle back
        reloaded.isAutomaticUpdateCheckEnabled = true
        reloaded.isAutomaticUpdateInstallEnabled = false

        let reloadedAgain = AppPreferences(userDefaults: testDefaults)
        XCTAssertTrue(reloadedAgain.isAutomaticUpdateCheckEnabled)
        XCTAssertFalse(reloadedAgain.isAutomaticUpdateInstallEnabled)
    }
}
