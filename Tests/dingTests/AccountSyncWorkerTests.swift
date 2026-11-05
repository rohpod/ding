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
            manualCheckClientFactory: { fakeClient },
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
            manualCheckClientFactory: { fakeClient },
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
            manualCheckClientFactory: { fakeClient },
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
            manualCheckClientFactory: { fakeClient },
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
            manualCheckClientFactory: { fakeClient },
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
            manualCheckClientFactory: { fakeClient },
            syncStateStore: syncStore,
            defaultSyncFrequency: .fiveMinutes,
            passwordProvider: { _ in "password" },
            sleepProvider: { duration in
                sleepDurations.withLock { $0.append(duration) }
                try await Task.sleep(nanoseconds: 10_000_000)
            },
            backoffJitter: { 0 }
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

    func testBackoffGrowsWhenFailureHappensAfterSelect() async throws {
        let account = Account(email: "test@example.com", provider: .gmail)
        let fakeClient = FakeIMAPClient()
        await fakeClient.setMailboxStatus(MailboxStatus(uidValidity: 1, uidNext: 10, messageCount: 5, recentCount: 0))
        await fakeClient.setFetchMessagesError(.timeout)

        let sleepDurations = LockProtected<[Duration]>([])
        let worker = AccountSyncWorker(
            account: account,
            imapClient: fakeClient,
            manualCheckClientFactory: { fakeClient },
            syncStateStore: syncStore,
            defaultSyncFrequency: .fiveMinutes,
            passwordProvider: { _ in "password" },
            sleepProvider: { duration in
                sleepDurations.withLock { $0.append(duration) }
                try await Task.sleep(nanoseconds: 10_000_000)
            },
            backoffJitter: { 0 }
        )

        await worker.start()
        for _ in 0..<100 {
            if sleepDurations.get().count >= 3 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await worker.stop()

        let seconds = sleepDurations.get().prefix(3).map { $0.components.seconds }
        XCTAssertEqual(Array(seconds), [5, 10, 20], "Failures after SELECT must keep escalating the backoff")
    }

    func testBackoffJitterIsAddedToDelay() async throws {
        let account = Account(email: "test@example.com", provider: .gmail)
        let fakeClient = FakeIMAPClient(connectError: .timeout)
        let sleepDurations = LockProtected<[Duration]>([])
        let worker = AccountSyncWorker(
            account: account,
            imapClient: fakeClient,
            manualCheckClientFactory: { fakeClient },
            syncStateStore: syncStore,
            passwordProvider: { _ in "password" },
            sleepProvider: { duration in
                sleepDurations.withLock { $0.append(duration) }
                try await Task.sleep(nanoseconds: 10_000_000)
            },
            backoffJitter: { 0.2 }
        )
        await worker.start()
        for _ in 0..<100 {
            if !sleepDurations.get().isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await worker.stop()
        XCTAssertEqual(sleepDurations.get().first?.components.seconds, 6)
    }

    func testIdleModeFetchesWaitingMailBeforeEnteringIdle() async throws {
        let account = Account(email: "idle-catchup@example.com", provider: .gmail, syncFrequency: .always)
        try syncStore.save([SyncState(accountID: account.id, uidValidity: 1, lastSeenUID: 100, lastSyncedAt: Date())])

        let fakeClient = FakeIMAPClient()
        await fakeClient.setMailboxStatus(MailboxStatus(uidValidity: 1, uidNext: 102, messageCount: 5, recentCount: 0))
        await fakeClient.setCannedMessages([MessageSummary(uid: 101, subject: "Overnight", from: "a@example.com", dateReceived: Date())])

        let events = LockProtected<[NewMailEvent]>([])
        let worker = AccountSyncWorker(
            account: account,
            imapClient: fakeClient,
            manualCheckClientFactory: { fakeClient },
            syncStateStore: syncStore,
            defaultSyncFrequency: .always,
            passwordProvider: { _ in "password" },
            sleepProvider: { _ in try await Task.sleep(nanoseconds: 60_000_000_000) },
            onNewMail: { event in events.withLock { $0.append(event) } }
        )

        await worker.start()
        for _ in 0..<100 {
            if await fakeClient.startIdleCallCount > 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await worker.stop()

        XCTAssertEqual(events.get().count, 1, "Mail that arrived while disconnected must be delivered on connect, not on the next push")
        XCTAssertEqual(events.get().first?.messages.map(\.uid), [101])
        let fetchCalls = await fakeClient.fetchNewMessagesCallCount
        XCTAssertGreaterThanOrEqual(fetchCalls, 1)
    }

    func testNewMailIsStillEmittedWhenPersistingStateFails() async throws {
        struct FailingSyncStore: SyncStateStoreProtocol {
            let seed: SyncState
            func load() throws -> [SyncState] { [seed] }
            func save(_ states: [SyncState]) throws { throw SyncStateStoreError.writeFailed(NSError(domain: "disk", code: 28)) }
            func state(forAccountID id: UUID) throws -> SyncState? { seed }
            func updateState(_ state: SyncState) throws { throw SyncStateStoreError.writeFailed(NSError(domain: "disk", code: 28)) }
            func removeState(forAccountID id: UUID) throws {}
        }

        let account = Account(email: "disk-full@example.com", provider: .gmail)
        let store = FailingSyncStore(seed: SyncState(accountID: account.id, uidValidity: 1, lastSeenUID: 10))
        let fakeClient = FakeIMAPClient()
        await fakeClient.setMailboxStatus(MailboxStatus(uidValidity: 1, uidNext: 12, messageCount: 3, recentCount: 0))
        await fakeClient.setCannedMessages([MessageSummary(uid: 11, subject: "Hi", from: "a@example.com", dateReceived: Date())])

        let events = LockProtected<[NewMailEvent]>([])
        let slept = LockProtected<Bool>(false)
        let worker = AccountSyncWorker(
            account: account,
            imapClient: fakeClient,
            manualCheckClientFactory: { fakeClient },
            syncStateStore: store,
            defaultSyncFrequency: .fiveMinutes,
            passwordProvider: { _ in "pw" },
            sleepProvider: { _ in
                slept.set(true)
                try await Task.sleep(nanoseconds: 10_000_000)
            },
            onNewMail: { event in events.withLock { $0.append(event) } }
        )

        await worker.start()
        for _ in 0..<100 {
            if slept.get() { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await worker.stop()

        XCTAssertEqual(events.get().count, 1, "A failed state write must not swallow the notification")
    }

    func testMissingKeychainItemStopsWorkerAndFlagsReauthentication() async throws {
        let account = Account(email: "missing-secret@example.com", provider: .gmail)
        let fakeClient = FakeIMAPClient()
        let flagged = LockProtected<Bool>(false)

        let worker = AccountSyncWorker(
            account: account,
            imapClient: fakeClient,
            manualCheckClientFactory: { fakeClient },
            syncStateStore: syncStore,
            passwordProvider: { _ in throw KeychainError.itemNotFound },
            reauthenticationHandler: { _ in flagged.set(true) },
            sleepProvider: { _ in try await Task.sleep(nanoseconds: 10_000_000) }
        )

        await worker.start()
        for _ in 0..<100 {
            if flagged.get() { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(flagged.get(), "A missing credential cannot recover by retrying; the user must re-enter it")
        let stillActive = await worker.active
        XCTAssertFalse(stillActive)
    }

    func testRepeatedAmbiguousLoginRejectionsEventuallyFlagReauthentication() async throws {
        let account = Account(email: "bare-no@example.com", provider: .gmail)
        let fakeClient = FakeIMAPClient(loginError: .loginRejected("Invalid credentials"))
        let flagCount = LockProtected<Int>(0)

        let worker = AccountSyncWorker(
            account: account,
            imapClient: fakeClient,
            manualCheckClientFactory: { fakeClient },
            syncStateStore: syncStore,
            passwordProvider: { _ in "pw" },
            reauthenticationHandler: { _ in flagCount.withLock { $0 += 1 } },
            sleepProvider: { _ in try await Task.sleep(nanoseconds: 5_000_000) },
            backoffJitter: { 0 }
        )

        await worker.start()
        for _ in 0..<200 {
            if flagCount.get() > 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(flagCount.get(), 1)
        let logins = await fakeClient.loginCallCount
        XCTAssertEqual(logins, 3, "Flag only after three consecutive ambiguous rejections")
        let active = await worker.active
        XCTAssertFalse(active)
    }

    func testTemporaryLoginRefusalNeverFlagsReauthentication() async throws {
        let account = Account(email: "busy@example.com", provider: .gmail)
        let fakeClient = FakeIMAPClient(loginError: .temporarilyUnavailable("too many connections"))
        let flagCount = LockProtected<Int>(0)

        let worker = AccountSyncWorker(
            account: account,
            imapClient: fakeClient,
            manualCheckClientFactory: { fakeClient },
            syncStateStore: syncStore,
            passwordProvider: { _ in "pw" },
            reauthenticationHandler: { _ in flagCount.withLock { $0 += 1 } },
            sleepProvider: { _ in try await Task.sleep(nanoseconds: 5_000_000) },
            backoffJitter: { 0 }
        )

        await worker.start()
        for _ in 0..<200 {
            if await fakeClient.loginCallCount >= 5 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let active = await worker.active
        await worker.stop()

        XCTAssertEqual(flagCount.get(), 0, "A temporary server refusal says nothing about the credentials")
        XCTAssertTrue(active, "The worker keeps retrying")
    }

    func testSuccessfulLoginClearsStaleReauthenticationFlagOnce() async throws {
        let account = Account(email: "stale@example.com", provider: .gmail, needsReauthentication: true)
        let fakeClient = FakeIMAPClient()
        let recovered = LockProtected<Int>(0)

        let worker = AccountSyncWorker(
            account: account,
            imapClient: fakeClient,
            manualCheckClientFactory: { fakeClient },
            syncStateStore: syncStore,
            defaultSyncFrequency: .oneMinute,
            passwordProvider: { _ in "pw" },
            authenticationRecoveredHandler: { _ in recovered.withLock { $0 += 1 } },
            sleepProvider: { _ in try await Task.sleep(nanoseconds: 5_000_000) }
        )

        await worker.start()
        for _ in 0..<100 {
            if await fakeClient.loginCallCount >= 3 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await worker.stop()

        XCTAssertEqual(recovered.get(), 1, "The flag is cleared on the first success, not on every poll")
    }

    func testUnflaggedAccountDoesNotInvokeRecoveryHandler() async throws {
        let account = Account(email: "fine@example.com", provider: .gmail)
        let fakeClient = FakeIMAPClient()
        let recovered = LockProtected<Int>(0)

        let worker = AccountSyncWorker(
            account: account,
            imapClient: fakeClient,
            manualCheckClientFactory: { fakeClient },
            syncStateStore: syncStore,
            defaultSyncFrequency: .oneMinute,
            passwordProvider: { _ in "pw" },
            authenticationRecoveredHandler: { _ in recovered.withLock { $0 += 1 } },
            sleepProvider: { _ in try await Task.sleep(nanoseconds: 5_000_000) }
        )

        await worker.start()
        for _ in 0..<50 {
            if await fakeClient.loginCallCount >= 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await worker.stop()
        XCTAssertEqual(recovered.get(), 0)
    }

    func testReconnectNowInterruptsPollSleepAndReconnectsImmediately() async throws {
        let account = Account(email: "wake@example.com", provider: .gmail)
        let fakeClient = FakeIMAPClient()

        let worker = AccountSyncWorker(
            account: account,
            imapClient: fakeClient,
            manualCheckClientFactory: { fakeClient },
            syncStateStore: syncStore,
            defaultSyncFrequency: .hourly,
            passwordProvider: { _ in "pw" },
            sleepProvider: { _ in try await Task.sleep(nanoseconds: 60_000_000_000) }
        )

        await worker.start()
        for _ in 0..<100 {
            if await fakeClient.connectCallCount >= 1, await !fakeClient.isConnected { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let before = await fakeClient.connectCallCount
        XCTAssertEqual(before, 1)

        await worker.reconnectNow()
        for _ in 0..<100 {
            if await fakeClient.connectCallCount > before { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let after = await fakeClient.connectCallCount
        await worker.stop()

        XCTAssertGreaterThan(after, before, "A wake/network event must not wait out a one-hour poll interval")
    }

    func testReconnectNowDropsIdleConnection() async throws {
        let account = Account(email: "idle-wake@example.com", provider: .gmail, syncFrequency: .always)
        let fakeClient = FakeIMAPClient()
        await fakeClient.setMailboxStatus(MailboxStatus(uidValidity: 1, uidNext: 10, messageCount: 1, recentCount: 0))

        let worker = AccountSyncWorker(
            account: account,
            imapClient: fakeClient,
            manualCheckClientFactory: { fakeClient },
            syncStateStore: syncStore,
            defaultSyncFrequency: .always,
            passwordProvider: { _ in "pw" },
            sleepProvider: { _ in try await Task.sleep(nanoseconds: 5_000_000) },
            backoffJitter: { 0 }
        )

        await worker.start()
        for _ in 0..<100 {
            if await fakeClient.startIdleCallCount >= 1 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let connectsBefore = await fakeClient.connectCallCount

        await worker.reconnectNow()
        for _ in 0..<300 {
            if await fakeClient.connectCallCount > connectsBefore { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let connectsAfter = await fakeClient.connectCallCount
        await worker.stop()

        XCTAssertGreaterThan(connectsAfter, connectsBefore, "A possibly dead IDLE socket must be replaced")
    }

    func testTransientTimeoutAndConnectionFailuresTriggerRetryWithoutPermanentStop() async throws {
        let account = Account(email: "timeout-test@example.com", provider: .icloud)

        // Part 1: Verify .timeout error produces scheduled retry with backoff and keeps worker active
        let timeoutClient = FakeIMAPClient(connectError: .timeout)
        let timeoutDelays = LockProtected<[Duration]>([])

        let timeoutWorker = AccountSyncWorker(
            account: account,
            imapClient: timeoutClient,
            manualCheckClientFactory: { timeoutClient },
            syncStateStore: syncStore,
            defaultSyncFrequency: .fiveMinutes,
            passwordProvider: { _ in "secret" },
            sleepProvider: { delay in
                timeoutDelays.withLock { $0.append(delay) }
                try await Task.sleep(nanoseconds: 10_000_000)
            },
            backoffJitter: { 0 }
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
            manualCheckClientFactory: { connFailClient },
            syncStateStore: syncStore,
            defaultSyncFrequency: .fiveMinutes,
            passwordProvider: { _ in "secret" },
            sleepProvider: { delay in
                connFailDelays.withLock { $0.append(delay) }
                try await Task.sleep(nanoseconds: 10_000_000)
            },
            backoffJitter: { 0 }
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
    func testKeychainAccessDeniedStopsWorkerAndInvokesReauth() async throws {
        let account = Account(email: "denied@example.com", provider: .gmail)
        let fakeClient = FakeIMAPClient()

        let reauthAccountID = LockProtected<UUID?>(nil)
        let sleepCalled = LockProtected<Bool>(false)

        let worker = AccountSyncWorker(
            account: account,
            imapClient: fakeClient,
            manualCheckClientFactory: { fakeClient },
            syncStateStore: syncStore,
            defaultSyncFrequency: .fiveMinutes,
            passwordProvider: { _ in
                throw KeychainError.accessDeniedOrCancelled
            },
            reauthenticationHandler: { id in
                reauthAccountID.set(id)
            },
            sleepProvider: { _ in
                sleepCalled.set(true)
            },
            backoffJitter: { 0 }
        )

        await worker.start()

        for _ in 0..<50 {
            if reauthAccountID.get() != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let isRunning = await worker.active
        XCTAssertFalse(isRunning, "Worker must stop immediately upon Keychain access denial")
        XCTAssertEqual(reauthAccountID.get(), account.id, "Reauthentication handler must be called with the target account ID")
        XCTAssertFalse(sleepCalled.get(), "Worker must not attempt backoff sleep or automatic retry on Keychain access denial")

        await worker.stop()
    }

    func testCheckUnreadCountWhenNotConnectedConnectsAndDisconnects() async throws {
        let account = Account(email: "unread-disconnected@example.com", provider: .gmail)
        let fakeClient = FakeIMAPClient()
        await fakeClient.setUnreadCount(7)

        let worker = AccountSyncWorker(
            account: account,
            imapClient: fakeClient,
            manualCheckClientFactory: { fakeClient },
            syncStateStore: syncStore,
            passwordProvider: { _ in "secret-pwd" }
        )

        let count = try await worker.checkUnreadCount()
        XCTAssertEqual(count, 7)

        let connectCalls = await fakeClient.connectCallCount
        let loginCalls = await fakeClient.loginCallCount
        let unreadCalls = await fakeClient.fetchUnreadCountCallCount
        let disconnectCalls = await fakeClient.disconnectCallCount
        let isConnected = await fakeClient.isConnected

        XCTAssertEqual(connectCalls, 1)
        XCTAssertEqual(loginCalls, 1)
        XCTAssertEqual(unreadCalls, 1)
        XCTAssertEqual(disconnectCalls, 1)
        XCTAssertFalse(isConnected)
    }

    func testCheckUnreadCountUsesSeparateClientAndLeavesSyncConnectionUntouched() async throws {
        let account = Account(email: "unread-connected@example.com", provider: .gmail, syncFrequency: .always)
        let syncClient = FakeIMAPClient()
        let manualClient = FakeIMAPClient()
        await syncClient.setMailboxStatus(MailboxStatus(uidValidity: 1, uidNext: 100, messageCount: 10, recentCount: 0))
        await manualClient.setUnreadCount(3)

        let worker = AccountSyncWorker(
            account: account,
            imapClient: syncClient,
            manualCheckClientFactory: { manualClient },
            syncStateStore: syncStore,
            defaultSyncFrequency: .always,
            passwordProvider: { _ in "secret" },
            sleepProvider: { _ in try await Task.sleep(nanoseconds: 60_000_000_000) }
        )

        await worker.start()
        for _ in 0..<50 {
            if await syncClient.startIdleCallCount > 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let syncDisconnectsBefore = await syncClient.disconnectCallCount
        let stopIdleBefore = await syncClient.stopIdleCallCount
        let count = try await worker.checkUnreadCount()
        XCTAssertEqual(count, 3)

        let syncUnreadCalls = await syncClient.fetchUnreadCountCallCount
        let syncDisconnectsAfter = await syncClient.disconnectCallCount
        let stopIdleAfter = await syncClient.stopIdleCallCount
        let syncStillConnected = await syncClient.isConnected
        let manualUnreadCalls = await manualClient.fetchUnreadCountCallCount
        let manualConnected = await manualClient.isConnected

        XCTAssertEqual(syncUnreadCalls, 0, "Manual checks must not run on the sync connection")
        XCTAssertEqual(syncDisconnectsAfter, syncDisconnectsBefore)
        XCTAssertEqual(stopIdleAfter, stopIdleBefore, "Manual checks must not interrupt IDLE")
        XCTAssertTrue(syncStillConnected)
        XCTAssertEqual(manualUnreadCalls, 1)
        XCTAssertFalse(manualConnected, "Dedicated manual-check client must be disconnected afterwards")

        await worker.stop()
    }

    func testCheckUnreadCountThrowsErrorAndDisconnectsWhenNotConnected() async throws {
        let account = Account(email: "unread-err@example.com", provider: .gmail)
        let fakeClient = FakeIMAPClient()
        await fakeClient.setFetchUnreadCountError(.unexpectedResponse("STATUS error"))

        let worker = AccountSyncWorker(
            account: account,
            imapClient: fakeClient,
            manualCheckClientFactory: { fakeClient },
            syncStateStore: syncStore,
            passwordProvider: { _ in "secret" }
        )

        do {
            _ = try await worker.checkUnreadCount()
            XCTFail("Expected checkUnreadCount to throw")
        } catch let error as IMAPClientError {
            XCTAssertEqual(error, .unexpectedResponse("STATUS error"))
        }

        let disconnectCalls = await fakeClient.disconnectCallCount
        XCTAssertEqual(disconnectCalls, 1, "Must disconnect even on query error")
    }
}

// MARK: - Thread-safe Test Box

final class WakeSignalTests: XCTestCase {
    func testWaitEnteredAlreadyCancelledReturnsPromptly() async throws {
        let signal = WakeSignal()
        let finished = LockProtected<Bool>(false)
        Task {
            await Task {
                withUnsafeCurrentTask { $0?.cancel() }
                await signal.wait()
            }.value
            finished.set(true)
        }
        for _ in 0..<50 {
            if finished.get() { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(finished.get(), "WakeSignal.wait() must not strand a continuation when entered cancelled")
    }

    func testSignalResumesAllWaiters() async throws {
        let signal = WakeSignal()
        let resumed = LockProtected<Int>(0)
        for _ in 0..<3 {
            Task { await signal.wait(); resumed.withLock { $0 += 1 } }
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        signal.signal()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(resumed.get(), 3)
    }
}

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
