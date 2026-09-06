import Combine
import XCTest
@testable import ding

final class SyncEngineTests: XCTestCase {
    private var tempDirectoryURL: URL!
    private var testStore: AccountStore!
    private var mockKeychain: InMemoryKeychainService!
    private var syncStore: SyncStateStore!

    override func setUp() {
        super.setUp()
        tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ding-syncengine-tests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = tempDirectoryURL.appendingPathComponent("accounts.json")
        testStore = AccountStore(fileURL: fileURL)
        mockKeychain = InMemoryKeychainService()
        let syncURL = tempDirectoryURL.appendingPathComponent("sync_state.json")
        syncStore = SyncStateStore(fileURL: syncURL)
    }

    override func tearDown() {
        if let tempDirectoryURL = tempDirectoryURL {
            try? FileManager.default.removeItem(at: tempDirectoryURL)
        }
        super.tearDown()
    }

    @MainActor
    func testSyncEngineStartsAndStopsWorkersForAccounts() throws {
        let manager = AccountManager(accountStore: testStore, keychainService: mockKeychain)
        _ = try manager.addAccount(email: "acc1@gmail.com", provider: .gmail, appPassword: "pwd")
        _ = try manager.addAccount(email: "acc2@fastmail.com", provider: .fastmail, appPassword: "pwd")

        let fakeClient1 = FakeIMAPClient()
        let fakeClient2 = FakeIMAPClient()
        let syncStore = self.syncStore!

        let engine = SyncEngine(
            accountManager: manager,
            workerFactory: { account, onNewMail in
                let client = account.email.contains("gmail") ? fakeClient1 : fakeClient2
                return AccountSyncWorker(
                    account: account,
                    imapClient: client,
                    syncStateStore: syncStore,
                    passwordProvider: { _ in "pwd" },
                    sleepProvider: { _ in try await Task.sleep(nanoseconds: 10_000_000) },
                    onNewMail: onNewMail
                )
            }
        )

        XCTAssertFalse(engine.isRunning)
        XCTAssertEqual(engine.workers.count, 0)

        engine.start()

        XCTAssertTrue(engine.isRunning)
        XCTAssertEqual(engine.workers.count, 2)

        engine.stop()

        XCTAssertFalse(engine.isRunning)
        XCTAssertEqual(engine.workers.count, 0)
    }

    @MainActor
    func testSyncEngineDynamicallyHandlesAccountAddAndRemove() throws {
        let manager = AccountManager(accountStore: testStore, keychainService: mockKeychain)
        let acc1 = try manager.addAccount(email: "user1@icloud.com", provider: .icloud, appPassword: "pwd")
        let syncStore = self.syncStore!

        let engine = SyncEngine(
            accountManager: manager,
            workerFactory: { account, onNewMail in
                AccountSyncWorker(
                    account: account,
                    imapClient: FakeIMAPClient(),
                    syncStateStore: syncStore,
                    passwordProvider: { _ in "pwd" },
                    sleepProvider: { _ in try await Task.sleep(nanoseconds: 10_000_000) },
                    onNewMail: onNewMail
                )
            }
        )

        engine.start()
        XCTAssertEqual(engine.workers.count, 1)
        XCTAssertNotNil(engine.workers[acc1.id])

        // Add account 2 dynamically
        let acc2 = try manager.addAccount(email: "user2@yahoo.com", provider: .yahoo, appPassword: "pwd")
        XCTAssertEqual(engine.workers.count, 2)
        XCTAssertNotNil(engine.workers[acc2.id])

        // Remove account 1 dynamically
        try manager.removeAccount(id: acc1.id)
        XCTAssertEqual(engine.workers.count, 1)
        XCTAssertNil(engine.workers[acc1.id])
        XCTAssertNotNil(engine.workers[acc2.id])

        engine.stop()
        XCTAssertEqual(engine.workers.count, 0)
    }

    @MainActor
    func testSyncEngineAggregatesEventsFromWorkers() async throws {
        let manager = AccountManager(accountStore: testStore, keychainService: mockKeychain)
        let acc = try manager.addAccount(email: "inbox@fastmail.com", provider: .fastmail, appPassword: "pwd")
        let syncStore = self.syncStore!

        let capturedEventCallback = LockProtected<(@Sendable (NewMailEvent) -> Void)?>(nil)

        let engine = SyncEngine(
            accountManager: manager,
            workerFactory: { account, onNewMail in
                capturedEventCallback.set(onNewMail)
                return AccountSyncWorker(
                    account: account,
                    imapClient: FakeIMAPClient(),
                    syncStateStore: syncStore,
                    passwordProvider: { _ in "pwd" },
                    sleepProvider: { _ in try await Task.sleep(nanoseconds: 10_000_000) },
                    onNewMail: onNewMail
                )
            }
        )

        var receivedFromCallback: NewMailEvent?
        engine.onNewMailDetected = { event in
            receivedFromCallback = event
        }

        let stream = engine.newMailStream()
        engine.start()

        // Synthesize an event emitted by worker
        let summary = MessageSummary(uid: 10, subject: "Hello", from: "Alice", dateReceived: Date())
        let testEvent = NewMailEvent(accountID: acc.id, messages: [summary])
        capturedEventCallback.get()?(testEvent)

        // Yield to allow the @MainActor task in createWorker to dispatch handleNewMailEvent
        for _ in 0..<20 {
            if receivedFromCallback != nil { break }
            await Task.yield()
        }

        // Verify callback
        XCTAssertEqual(receivedFromCallback, testEvent)

        // Verify stream
        var streamIterator = stream.makeAsyncIterator()
        let receivedFromStream = await streamIterator.next()
        XCTAssertEqual(receivedFromStream, testEvent)

        engine.stop()
    }

    @MainActor
    func testSyncEngineWithZeroAccountsStartsZeroWorkers() throws {
        let manager = AccountManager(accountStore: testStore, keychainService: mockKeychain)
        XCTAssertTrue(manager.accounts.isEmpty)
        let syncStore = self.syncStore!

        let engine = SyncEngine(
            accountManager: manager,
            workerFactory: { account, onNewMail in
                AccountSyncWorker(
                    account: account,
                    imapClient: FakeIMAPClient(),
                    syncStateStore: syncStore,
                    passwordProvider: { _ in "pwd" },
                    sleepProvider: { _ in try await Task.sleep(nanoseconds: 10_000_000) },
                    onNewMail: onNewMail
                )
            }
        )

        XCTAssertFalse(engine.isRunning)
        XCTAssertEqual(engine.workers.count, 0)

        // Starting with zero accounts must cleanly transition isRunning to true with 0 workers
        engine.start()

        XCTAssertTrue(engine.isRunning)
        XCTAssertEqual(engine.workers.count, 0)
        XCTAssertTrue(engine.workers.isEmpty)

        engine.stop()
        XCTAssertFalse(engine.isRunning)
        XCTAssertEqual(engine.workers.count, 0)
    }

    @MainActor
    func testSyncEngineRemovingLastAccountTearsDownWorker() async throws {
        let manager = AccountManager(accountStore: testStore, keychainService: mockKeychain)
        let acc = try manager.addAccount(email: "solo@fastmail.com", provider: .fastmail, appPassword: "pwd")
        let syncStore = self.syncStore!

        let capturedWorker = LockProtected<AccountSyncWorker?>(nil)

        let engine = SyncEngine(
            accountManager: manager,
            workerFactory: { account, onNewMail in
                let worker = AccountSyncWorker(
                    account: account,
                    imapClient: FakeIMAPClient(),
                    syncStateStore: syncStore,
                    passwordProvider: { _ in "pwd" },
                    sleepProvider: { _ in try await Task.sleep(nanoseconds: 10_000_000) },
                    onNewMail: onNewMail
                )
                capturedWorker.set(worker)
                return worker
            }
        )

        engine.start()
        XCTAssertEqual(engine.workers.count, 1)
        XCTAssertNotNil(engine.workers[acc.id])

        guard let worker = capturedWorker.get() else {
            XCTFail("Worker was not initialized")
            return
        }

        // Wait briefly for worker to start
        for _ in 0..<20 {
            if await worker.active { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let isActiveBeforeRemoval = await worker.active
        XCTAssertTrue(isActiveBeforeRemoval, "Worker must be running before account removal")

        // Dynamically remove the single remaining account
        try manager.removeAccount(id: acc.id)

        // Verify SyncEngine workers dictionary is now empty
        XCTAssertEqual(engine.workers.count, 0)
        XCTAssertNil(engine.workers[acc.id])
        XCTAssertTrue(engine.workers.isEmpty)

        // Wait for the asynchronous teardown task to stop the worker
        for _ in 0..<20 {
            if !(await worker.active) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let isActiveAfterRemoval = await worker.active
        XCTAssertFalse(isActiveAfterRemoval, "Worker must be stopped when the last account is removed")

        engine.stop()
    }

    @MainActor
    func testCheckAllMailRespectsIncludeInManualCheck() async throws {
        let manager = AccountManager(accountStore: testStore, keychainService: mockKeychain)
        var acc1 = try manager.addAccount(email: "included@gmail.com", provider: .gmail, appPassword: "pwd")
        acc1.includeInManualCheck = true
        try manager.updateAccount(acc1)

        var acc2 = try manager.addAccount(email: "excluded@fastmail.com", provider: .fastmail, appPassword: "pwd")
        acc2.includeInManualCheck = false
        try manager.updateAccount(acc2)

        let fakeClient1 = FakeIMAPClient()
        await fakeClient1.setMailboxStatus(MailboxStatus(uidValidity: 1, uidNext: 100, messageCount: 10, recentCount: 0))

        let fakeClient2 = FakeIMAPClient()
        await fakeClient2.setMailboxStatus(MailboxStatus(uidValidity: 1, uidNext: 100, messageCount: 10, recentCount: 0))

        let acc1ID = acc1.id
        let acc2ID = acc2.id

        let syncStore = self.syncStore!
        let sleep1Called = LockProtected<Bool>(false)
        let sleep2Called = LockProtected<Bool>(false)

        let engine = SyncEngine(
            accountManager: manager,
            workerFactory: { account, onNewMail in
                let client = account.id == acc1ID ? fakeClient1 : fakeClient2
                let sleepBox = account.id == acc1ID ? sleep1Called : sleep2Called
                return AccountSyncWorker(
                    account: account,
                    imapClient: client,
                    syncStateStore: syncStore,
                    defaultSyncFrequency: .fifteenMinutes,
                    passwordProvider: { _ in "pwd" },
                    sleepProvider: { _ in
                        sleepBox.set(true)
                        try await Task.sleep(nanoseconds: 60_000_000_000)
                    },
                    onNewMail: onNewMail
                )
            }
        )

        engine.start()

        // Wait for both workers to complete baseline and enter sleep
        for _ in 0..<50 {
            if sleep1Called.get() && sleep2Called.get() { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(sleep1Called.get())
        XCTAssertTrue(sleep2Called.get())

        let fetchCount1Before = await fakeClient1.fetchNewMessagesCallCount
        let fetchCount2Before = await fakeClient2.fetchNewMessagesCallCount

        // Add canned messages
        let msg1 = MessageSummary(uid: 101, subject: "M1", from: "a@example.com", dateReceived: Date())
        let msg2 = MessageSummary(uid: 102, subject: "M2", from: "b@example.com", dateReceived: Date())
        await fakeClient1.setCannedMessages([msg1])
        await fakeClient2.setCannedMessages([msg2])

        // Call checkAllMail() - should check acc1 (included) but NOT acc2 (excluded)
        await engine.checkAllMail()

        let fetchCount1After = await fakeClient1.fetchNewMessagesCallCount
        let fetchCount2After = await fakeClient2.fetchNewMessagesCallCount

        XCTAssertGreaterThan(fetchCount1After, fetchCount1Before, "Included account must be checked")
        XCTAssertEqual(fetchCount2After, fetchCount2Before, "Excluded account must not be checked by checkAllMail")

        // Call checkMail(accountID:) directly for acc2 - should check acc2 even if excluded from global check
        await engine.checkMail(accountID: acc2ID)

        // Verify manualCheckAccounts list for menu bar reflects only included accounts
        XCTAssertEqual(engine.manualCheckAccounts.count, 1)
        XCTAssertEqual(engine.manualCheckAccounts.first?.id, acc1ID)

        engine.stop()
    }

    @MainActor
    func testManualCheckAccountsReflectsIncludeInManualCheckAndUpdatesDynamically() throws {
        let manager = AccountManager(accountStore: testStore, keychainService: mockKeychain)
        var acc1 = try manager.addAccount(email: "user1@example.com", provider: .gmail, appPassword: "pwd")
        acc1.includeInManualCheck = true
        try manager.updateAccount(acc1)

        var acc2 = try manager.addAccount(email: "user2@example.com", provider: .fastmail, appPassword: "pwd")
        acc2.includeInManualCheck = false
        try manager.updateAccount(acc2)

        let engine = SyncEngine(accountManager: manager)

        // Only acc1 is included initially
        XCTAssertEqual(engine.manualCheckAccounts.count, 1)
        XCTAssertEqual(engine.manualCheckAccounts.first?.id, acc1.id)

        // Enable manual check for acc2
        acc2.includeInManualCheck = true
        try manager.updateAccount(acc2)

        XCTAssertEqual(engine.manualCheckAccounts.count, 2)
        XCTAssertTrue(engine.manualCheckAccounts.contains(where: { $0.id == acc2.id }))

        // Disable manual check for acc1
        acc1.includeInManualCheck = false
        try manager.updateAccount(acc1)

        XCTAssertEqual(engine.manualCheckAccounts.count, 1)
        XCTAssertEqual(engine.manualCheckAccounts.first?.id, acc2.id)
    }
}
