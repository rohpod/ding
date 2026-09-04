import XCTest
@testable import ding

final class AccountSyncWorkerTests: XCTestCase {
    private var tempDir: URL!
    private var syncStore: SyncStateStore!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = tempDir.appendingPathComponent("sync_state.json")
        syncStore = SyncStateStore(fileURL: fileURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testInitialSyncEstablishesBaselineWithoutEmittingNewMail() async throws {
        let account = Account(email: "test@example.com", provider: .gmail)
        let fakeClient = FakeIMAPClient()
        await fakeClient.setMailboxStatus(MailboxStatus(uidValidity: 10, uidNext: 150, messageCount: 50, recentCount: 0))

        let receivedEvents = LockProtected<[NewMailEvent]>([])
        let sleepCalled = LockProtected<Bool>(false)

        let worker = AccountSyncWorker(
            account: account,
            imapClient: fakeClient,
            syncStateStore: syncStore,
            defaultSyncFrequency: .fiveMinutes,
            passwordProvider: { _ in "secret-password" },
            sleepProvider: { duration in
                sleepCalled.set(true)
                // Short sleep to allow test to cancel
                try await Task.sleep(nanoseconds: 10_000_000)
            },
            onNewMail: { event in
                receivedEvents.withLock { $0.append(event) }
            }
        )

        await worker.start()

        // Wait until sleepProvider is reached (meaning initial sync and poll completed)
        for _ in 0..<50 {
            if sleepCalled.get() { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        await worker.stop()

        // Verify baseline state: lastSeenUID must be uidNext - 1 (149)
        let savedState = try syncStore.state(forAccountID: account.id)
        XCTAssertNotNil(savedState)
        XCTAssertEqual(savedState?.uidValidity, 10)
        XCTAssertEqual(savedState?.lastSeenUID, 149)

        // No new mail event should be emitted for pre-existing mailbox history
        XCTAssertTrue(receivedEvents.get().isEmpty, "Initial baseline establishment must not emit historical mail notifications")
    }

    func testUIDValidityChangeResetsBaselineWithoutEmittingHistoricalMail() async throws {
        let account = Account(email: "test@example.com", provider: .fastmail)

        // Seed store with an old UIDVALIDITY and lastSeenUID
        let oldState = SyncState(
            accountID: account.id,
            uidValidity: 100,
            lastSeenUID: 500,
            lastSyncedAt: Date()
        )
        try syncStore.save([oldState])

        // Server now reports new UIDVALIDITY (e.g. 200) with uidNext = 50
        let fakeClient = FakeIMAPClient()
        await fakeClient.setMailboxStatus(MailboxStatus(uidValidity: 200, uidNext: 50, messageCount: 20, recentCount: 0))

        let receivedEvents = LockProtected<[NewMailEvent]>([])
        let sleepCalled = LockProtected<Bool>(false)

        let worker = AccountSyncWorker(
            account: account,
            imapClient: fakeClient,
            syncStateStore: syncStore,
            defaultSyncFrequency: .fifteenMinutes,
            passwordProvider: { _ in "secret-password" },
            sleepProvider: { duration in
                sleepCalled.set(true)
                try await Task.sleep(nanoseconds: 10_000_000)
            },
            onNewMail: { event in
                receivedEvents.withLock { $0.append(event) }
            }
        )

        await worker.start()

        for _ in 0..<50 {
            if sleepCalled.get() { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        await worker.stop()

        // Verify that lastSeenUID was reset to uidNext - 1 (49) and uidValidity is 200
        let updatedState = try syncStore.state(forAccountID: account.id)
        XCTAssertNotNil(updatedState)
        XCTAssertEqual(updatedState?.uidValidity, 200)
        XCTAssertEqual(updatedState?.lastSeenUID, 49)
        XCTAssertTrue(receivedEvents.get().isEmpty, "UIDVALIDITY change must reset baseline without notifying mailbox contents")
    }

    func testNewMessagesArrivingEmitNewMailEvent() async throws {
        let account = Account(email: "test@example.com", provider: .icloud)

        // Existing state: lastSeenUID is 100
        let existing = SyncState(
            accountID: account.id,
            uidValidity: 50,
            lastSeenUID: 100,
            lastSyncedAt: Date()
        )
        try syncStore.save([existing])

        let fakeClient = FakeIMAPClient()
        await fakeClient.setMailboxStatus(MailboxStatus(uidValidity: 50, uidNext: 103, messageCount: 15, recentCount: 2))

        let msg1 = MessageSummary(uid: 101, subject: "Welcome", from: "Service <service@example.com>", dateReceived: Date())
        let msg2 = MessageSummary(uid: 102, subject: "Invoice", from: "Billing <billing@example.com>", dateReceived: Date())
        await fakeClient.setCannedMessages([msg1, msg2])

        let receivedEvents = LockProtected<[NewMailEvent]>([])
        let sleepCalled = LockProtected<Bool>(false)

        let worker = AccountSyncWorker(
            account: account,
            imapClient: fakeClient,
            syncStateStore: syncStore,
            defaultSyncFrequency: .hourly,
            passwordProvider: { _ in "secret-password" },
            sleepProvider: { duration in
                sleepCalled.set(true)
                try await Task.sleep(nanoseconds: 10_000_000)
            },
            onNewMail: { event in
                receivedEvents.withLock { $0.append(event) }
            }
        )

        await worker.start()

        for _ in 0..<50 {
            if sleepCalled.get() { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        await worker.stop()

        let events = receivedEvents.get()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.accountID, account.id)
        XCTAssertEqual(events.first?.messages.count, 2)
        XCTAssertEqual(events.first?.messages[0].uid, 101)
        XCTAssertEqual(events.first?.messages[1].uid, 102)

        // Verify updated sync state
        let updatedState = try syncStore.state(forAccountID: account.id)
        XCTAssertEqual(updatedState?.lastSeenUID, 102)
    }

    func testAuthenticationFailureStopsWorkerAndInvokesReauth() async throws {
        let account = Account(email: "test@example.com", provider: .yahoo)
        let fakeClient = FakeIMAPClient(loginError: .authenticationFailed)

        let reauthAccountID = LockProtected<UUID?>(nil)

        let worker = AccountSyncWorker(
            account: account,
            imapClient: fakeClient,
            syncStateStore: syncStore,
            defaultSyncFrequency: .fiveMinutes,
            passwordProvider: { _ in "wrong-password" },
            reauthenticationHandler: { id in
                reauthAccountID.set(id)
            }
        )

        await worker.start()

        // Wait a short duration for the authentication error to halt the worker
        for _ in 0..<50 {
            if reauthAccountID.get() != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let isRunning = await worker.active
        XCTAssertFalse(isRunning, "Worker must stop immediately upon authentication failure")
        XCTAssertEqual(reauthAccountID.get(), account.id, "Reauthentication handler must be called with the target account ID")

        await worker.stop()
    }

    func testFallbackToPollingWhenServerLacksIdle() async throws {
        let account = Account(email: "test@example.com", provider: .fastmail, syncFrequency: .always)
        let fakeClient = FakeIMAPClient()
        await fakeClient.setSupportsIdle(false)
        await fakeClient.setMailboxStatus(MailboxStatus(uidValidity: 1, uidNext: 10, messageCount: 5, recentCount: 0))

        let sleepDurations = LockProtected<[Duration]>([])

        let worker = AccountSyncWorker(
            account: account,
            imapClient: fakeClient,
            syncStateStore: syncStore,
            defaultSyncFrequency: .always,
            passwordProvider: { _ in "password" },
            sleepProvider: { duration in
                sleepDurations.withLock { $0.append(duration) }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        )

        await worker.start()

        for _ in 0..<50 {
            if !sleepDurations.get().isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        await worker.stop()

        // When .always is set but IDLE is unsupported, fallback interval must be 60s
        let durations = sleepDurations.get()
        XCTAssertFalse(durations.isEmpty)
        XCTAssertEqual(durations.first?.components.seconds, 60, "Fallback interval should be 60 seconds")
    }

    func testBackoffTimingIncreasesOnTransientErrors() async throws {
        let account = Account(email: "test@example.com", provider: .gmail)
        let underlying = NSError(domain: "test", code: -1004)
        let fakeClient = FakeIMAPClient(connectError: .connectionFailed(underlying: underlying))

        let sleepDurations = LockProtected<[Duration]>([])

        let worker = AccountSyncWorker(
            account: account,
            imapClient: fakeClient,
            syncStateStore: syncStore,
            defaultSyncFrequency: .fiveMinutes,
            passwordProvider: { _ in "password" },
            sleepProvider: { duration in
                sleepDurations.withLock { $0.append(duration) }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        )

        await worker.start()

        for _ in 0..<100 {
            if sleepDurations.get().count >= 3 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        await worker.stop()

        let durations = sleepDurations.get()
        XCTAssertGreaterThanOrEqual(durations.count, 3)
        // Backoff sequence: attempt 0: 5s, attempt 1: 10s, attempt 2: 20s
        XCTAssertEqual(durations[0].components.seconds, 5)
        XCTAssertEqual(durations[1].components.seconds, 10)
        XCTAssertEqual(durations[2].components.seconds, 20)
    }

    func testTransientTimeoutAndConnectionFailuresTriggerRetryWithoutPermanentStop() async throws {
        let account = Account(email: "timeout-test@example.com", provider: .icloud)

        // Part 1: Verify .timeout error produces scheduled retry with backoff and keeps worker active
        let timeoutClient = FakeIMAPClient(connectError: .timeout)
        let timeoutDelays = LockProtected<[Duration]>([])

        let timeoutWorker = AccountSyncWorker(
            account: account,
            imapClient: timeoutClient,
            syncStateStore: syncStore,
            defaultSyncFrequency: .fiveMinutes,
            passwordProvider: { _ in "secret" },
            sleepProvider: { delay in
                timeoutDelays.withLock { $0.append(delay) }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        )

        await timeoutWorker.start()

        for _ in 0..<50 {
            if timeoutDelays.get().count >= 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        // Worker must remain active throughout transient timeout retries
        let isTimeoutWorkerActive = await timeoutWorker.active
        XCTAssertTrue(isTimeoutWorkerActive, "Worker must NOT permanently halt on transient .timeout")
        let capturedTimeoutDelays = timeoutDelays.get()
        XCTAssertGreaterThanOrEqual(capturedTimeoutDelays.count, 2)
        XCTAssertEqual(capturedTimeoutDelays[0].components.seconds, 5)
        XCTAssertEqual(capturedTimeoutDelays[1].components.seconds, 10)

        await timeoutWorker.stop()

        // Part 2: Verify .connectionFailed error produces scheduled retry with backoff and keeps worker active
        let connFailClient = FakeIMAPClient(connectError: .connectionFailed(underlying: NSError(domain: "test", code: -1009)))
        let connFailDelays = LockProtected<[Duration]>([])

        let connFailWorker = AccountSyncWorker(
            account: account,
            imapClient: connFailClient,
            syncStateStore: syncStore,
            defaultSyncFrequency: .fiveMinutes,
            passwordProvider: { _ in "secret" },
            sleepProvider: { delay in
                connFailDelays.withLock { $0.append(delay) }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        )

        await connFailWorker.start()

        for _ in 0..<50 {
            if connFailDelays.get().count >= 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        // Worker must remain active throughout transient connection failure retries
        let isConnFailWorkerActive = await connFailWorker.active
        XCTAssertTrue(isConnFailWorkerActive, "Worker must NOT permanently halt on transient .connectionFailed")
        let capturedConnDelays = connFailDelays.get()
        XCTAssertGreaterThanOrEqual(capturedConnDelays.count, 2)
        XCTAssertEqual(capturedConnDelays[0].components.seconds, 5)
        XCTAssertEqual(capturedConnDelays[1].components.seconds, 10)

        await connFailWorker.stop()
    }
}

// MARK: - Thread-safe Test Box

final class LockProtected<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(_ initialValue: T) {
        self.value = initialValue
    }

    func get() -> T {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: T) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }

    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
