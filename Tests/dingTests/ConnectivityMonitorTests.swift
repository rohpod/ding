import Network
import XCTest
@testable import ding

@MainActor
final class ConnectivityMonitorTests: XCTestCase {
    func testBurstOfTriggersCollapsesIntoOneReconnect() async throws {
        let monitor = ConnectivityMonitor(debounce: .milliseconds(60))
        var count = 0
        monitor.onReconnectNeeded = { count += 1 }

        monitor.scheduleTrigger()
        monitor.scheduleTrigger()
        monitor.scheduleTrigger()
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(count, 1)
    }

    func testOnlyTransitionIntoSatisfiedTriggers() async throws {
        let monitor = ConnectivityMonitor(debounce: .milliseconds(20))
        var count = 0
        monitor.onReconnectNeeded = { count += 1 }

        monitor.handlePathUpdate(status: .satisfied)      // initial report: no trigger
        monitor.handlePathUpdate(status: .satisfied)      // unchanged: no trigger
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(count, 0)

        monitor.handlePathUpdate(status: .unsatisfied)    // going offline: nothing to reconnect yet
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(count, 0)

        monitor.handlePathUpdate(status: .satisfied)      // back online
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(count, 1)
    }

    func testStopCancelsPendingTrigger() async throws {
        let monitor = ConnectivityMonitor(debounce: .milliseconds(80))
        var count = 0
        monitor.onReconnectNeeded = { count += 1 }
        monitor.start()
        monitor.scheduleTrigger()
        monitor.stop()
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(count, 0)
    }

    func testEveryStatusChangeReportsAvailability() {
        let monitor = ConnectivityMonitor(debounce: .milliseconds(20))
        var reports: [Bool] = []
        monitor.onNetworkAvailabilityChanged = { reports.append($0) }

        monitor.handlePathUpdate(status: .satisfied)      // initial report still counts
        monitor.handlePathUpdate(status: .unsatisfied)    // going offline is reported even though it triggers nothing
        monitor.handlePathUpdate(status: .satisfied)

        XCTAssertEqual(reports, [true, false, true])
    }
}
