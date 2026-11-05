import XCTest
@testable import ding

/// Records every snapshot a worker publishes, so tests can wait on a condition with a deadline instead of sleeping.
final class HealthRecorder: @unchecked Sendable {
    private let snapshots = LockProtected<[AccountHealth]>([])
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<AccountHealth>) {
        let snapshots = snapshots
        task = Task {
            for await health in stream {
                snapshots.withLock { $0.append(health) }
            }
        }
    }

    deinit { task?.cancel() }

    var all: [AccountHealth] { snapshots.get() }

    /// Polls until some recorded snapshot satisfies `predicate` or the deadline passes.
    @discardableResult
    func wait(timeout: TimeInterval = 5, for predicate: (AccountHealth) -> Bool) async throws -> AccountHealth? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let match = all.first(where: predicate) { return match }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        return nil
    }
}

final class AccountHealthFormatterTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private let locale = Locale(identifier: "en_US")

    // 2026-03-10 14:41 UTC
    private let now = Date(timeIntervalSince1970: 1_773_153_660)

    private func summary(
        account: Account = Account(email: "a@gmail.com", provider: .gmail),
        health: AccountHealth?,
        online: Bool = true
    ) -> String {
        // Newer ICU separates the time from "PM" with a narrow no-break space; compare with a plain one.
        AccountHealthFormatter.summary(
            account: account, health: health, isNetworkAvailable: online,
            now: now, calendar: calendar, locale: locale
        ).replacingOccurrences(of: "\u{202F}", with: " ")
    }

    func testReauthenticationWinsOverEverything() {
        var account = Account(email: "a@gmail.com", provider: .gmail)
        account.needsReauthentication = true
        XCTAssertEqual(summary(account: account, health: AccountHealth(connection: .push), online: false), "Password needed")
    }

    func testOfflineWinsOverHealth() {
        XCTAssertEqual(summary(health: AccountHealth(connection: .push, lastSuccessfulCheck: now), online: false), "Offline")
    }

    func testMissingOrFreshHealthIsConnecting() {
        XCTAssertEqual(summary(health: nil), "Connecting…")
        XCTAssertEqual(summary(health: AccountHealth(connection: .connecting)), "Connecting…")
    }

    func testDegradedShowsLastCheckOrNot() {
        let failing = AccountHealth(connection: .retrying, lastSuccessfulCheck: now, consecutiveFailures: AccountHealth.degradedThreshold)
        XCTAssertEqual(summary(health: failing), "Can't connect, last checked 2:41 PM")
        XCTAssertEqual(summary(health: AccountHealth(connection: .retrying, consecutiveFailures: 4)), "Can't connect")
    }

    func testTransientFailureOnlyShowsReconnecting() {
        let flap = AccountHealth(connection: .retrying, lastSuccessfulCheck: now, consecutiveFailures: AccountHealth.degradedThreshold - 1)
        XCTAssertEqual(summary(health: flap), "Reconnecting…")
    }

    func testPushAndPollingSummaries() {
        XCTAssertEqual(summary(health: AccountHealth(connection: .push, lastSuccessfulCheck: now)), "Live, checked 2:41 PM")
        XCTAssertEqual(
            summary(health: AccountHealth(connection: .polling(intervalSeconds: 300, idleUnsupported: false), lastSuccessfulCheck: now)),
            "Every 5 min, checked 2:41 PM"
        )
        XCTAssertEqual(
            summary(health: AccountHealth(connection: .polling(intervalSeconds: 60, idleUnsupported: true), lastSuccessfulCheck: now)),
            "Every 1 min (no push support), checked 2:41 PM"
        )
    }

    func testPollingIntervalRoundsToWholeMinutes() {
        let health = AccountHealth(connection: .polling(intervalSeconds: 90, idleUnsupported: false), lastSuccessfulCheck: now)
        XCTAssertEqual(summary(health: health), "Every 2 min, checked 2:41 PM")
    }

    func testPreviousDayIncludesDate() {
        let yesterday = now.addingTimeInterval(-86_400)
        let text = summary(health: AccountHealth(connection: .push, lastSuccessfulCheck: yesterday))
        XCTAssertEqual(text, "Live, checked 3/9/26, 2:41 PM")
    }

    func testDegradedThreshold() {
        XCTAssertFalse(AccountHealth(consecutiveFailures: 3).isDegraded)
        XCTAssertTrue(AccountHealth(consecutiveFailures: 4).isDegraded)
    }
}

final class AccountWorkerHealthTests: XCTestCase {
    private var tempDir: URL!
    private var syncStore: SyncStateStore!
    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        syncStore = SyncStateStore(fileURL: tempDir.appendingPathComponent("sync_state.json"))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func makeWorker(
        _ client: FakeIMAPClient,
        frequency: SyncFrequency = .fiveMinutes,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in try await Task.sleep(nanoseconds: 5_000_000) }
    ) -> AccountSyncWorker {
        AccountSyncWorker(
            account: Account(email: "h@example.com", provider: .gmail),
            imapClient: client,
            manualCheckClientFactory: { client },
            syncStateStore: syncStore,
            defaultSyncFrequency: frequency,
            passwordProvider: { _ in "pw" },
            sleepProvider: sleep,
            backoffJitter: { 0 },
            now: { [fixedNow] in fixedNow }
        )
    }

    func testStartPublishesConnecting() async throws {
        let client = FakeIMAPClient()
        let worker = makeWorker(client, sleep: { _ in try await Task.sleep(nanoseconds: 60_000_000_000) })
        let recorder = HealthRecorder(worker.healthUpdates)
        await worker.start()

        let first = try await recorder.wait { _ in true }
        await worker.stop()
        XCTAssertEqual(first?.connection, .connecting)
    }

    func testEmptyFetchStillRecordsSuccess() async throws {
        let client = FakeIMAPClient()
        let worker = makeWorker(client)
        let recorder = HealthRecorder(worker.healthUpdates)
        await worker.start()

        let ok = try await recorder.wait { $0.lastSuccessfulCheck != nil }
        await worker.stop()
        XCTAssertEqual(ok?.lastSuccessfulCheck, fixedNow, "A quiet inbox must still count as a successful check")
        XCTAssertEqual(ok?.consecutiveFailures, 0)
    }

    func testFailureIncrementsThenSuccessResets() async throws {
        let client = FakeIMAPClient()
        await client.setFetchMessagesError(.timeout)
        let worker = makeWorker(client)
        let recorder = HealthRecorder(worker.healthUpdates)
        await worker.start()

        let failing = try await recorder.wait { $0.consecutiveFailures >= 2 }
        XCTAssertEqual(failing?.connection, .retrying)
        XCTAssertNotNil(failing?.lastErrorMessage)
        XCTAssertNil(failing?.lastSuccessfulCheck)

        await client.setFetchMessagesError(nil)
        let recovered = try await recorder.wait { $0.lastSuccessfulCheck != nil && $0.consecutiveFailures == 0 }
        await worker.stop()
        XCTAssertNotNil(recovered)
        XCTAssertNil(recovered?.lastErrorMessage)
    }

    func testPollCyclesDoNotRepublishConnecting() async throws {
        let client = FakeIMAPClient()
        let worker = makeWorker(client)
        let recorder = HealthRecorder(worker.healthUpdates)
        await worker.start()

        for _ in 0..<400 {
            if await client.connectCallCount >= 4 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        await worker.stop()
        try await Task.sleep(nanoseconds: 20_000_000)

        let connects = await client.connectCallCount
        XCTAssertGreaterThanOrEqual(connects, 4)
        // `bufferingNewest(1)` may drop intermediate snapshots, so assert on the absence of a late `.connecting`.
        let connecting = recorder.all.filter { $0.connection == .connecting }
        XCTAssertLessThanOrEqual(connecting.count, 1)
        if let lastSuccess = recorder.all.lastIndex(where: { $0.lastSuccessfulCheck != nil }) {
            XCTAssertFalse(recorder.all[lastSuccess...].contains { $0.connection == .connecting })
        }
    }

    func testIdleUnsupportedIsReported() async throws {
        let client = FakeIMAPClient()
        await client.setSupportsIdle(false)
        let worker = makeWorker(client, frequency: .always)
        let recorder = HealthRecorder(worker.healthUpdates)
        await worker.start()

        let polling = try await recorder.wait { $0.connection == .polling(intervalSeconds: 60, idleUnsupported: true) }
        await worker.stop()
        XCTAssertNotNil(polling)
    }

    func testPeriodicPollingReportsItsInterval() async throws {
        let client = FakeIMAPClient()
        let worker = makeWorker(client, frequency: .fiveMinutes)
        let recorder = HealthRecorder(worker.healthUpdates)
        await worker.start()

        let polling = try await recorder.wait { $0.connection == .polling(intervalSeconds: 300, idleUnsupported: false) }
        await worker.stop()
        XCTAssertNotNil(polling)
    }

    func testIdleModeReportsPush() async throws {
        let client = FakeIMAPClient()
        let worker = makeWorker(client, frequency: .always, sleep: { _ in try await Task.sleep(nanoseconds: 60_000_000_000) })
        let recorder = HealthRecorder(worker.healthUpdates)
        await worker.start()

        let push = try await recorder.wait { $0.connection == .push }
        await worker.stop()
        XCTAssertEqual(push?.lastSuccessfulCheck, fixedNow)
    }

    func testReconnectNowIsNotCountedAsAFailure() async throws {
        let client = FakeIMAPClient()
        let worker = makeWorker(client, frequency: .always)
        let recorder = HealthRecorder(worker.healthUpdates)
        await worker.start()
        try await recorder.wait { $0.connection == .push }

        let connectsBefore = await client.connectCallCount
        await worker.reconnectNow()
        for _ in 0..<400 {
            if await client.connectCallCount > connectsBefore, await client.startIdleCallCount >= 2 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        await worker.stop()

        let connectsAfter = await client.connectCallCount
        XCTAssertGreaterThan(connectsAfter, connectsBefore)
        XCTAssertTrue(recorder.all.allSatisfy { $0.consecutiveFailures == 0 }, "A deliberate reconnect must not look like an outage")
    }
}
