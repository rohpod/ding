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
}
