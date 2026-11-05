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
                    manualCheckClientFactory: { client },
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
                    manualCheckClientFactory: { FakeIMAPClient() },
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
                    manualCheckClientFactory: { FakeIMAPClient() },
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
                    manualCheckClientFactory: { FakeIMAPClient() },
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
                    manualCheckClientFactory: { FakeIMAPClient() },
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
                    manualCheckClientFactory: { client },
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

        let unreadCount1Before = await fakeClient1.fetchUnreadCountCallCount
        let unreadCount2Before = await fakeClient2.fetchUnreadCountCallCount

        var capturedNotifications: [ManualCheckNotification] = []
        engine.onManualCheckNotification = { capturedNotifications.append($0) }

        await fakeClient1.setUnreadCount(3)
        await fakeClient2.setUnreadCount(5)

        // Call checkAllMail() - should check acc1 (included) but NOT acc2 (excluded)
        await engine.checkAllMail()

        let unreadCount1After = await fakeClient1.fetchUnreadCountCallCount
        let unreadCount2After = await fakeClient2.fetchUnreadCountCallCount

        XCTAssertGreaterThan(unreadCount1After, unreadCount1Before, "Included account must be checked")
        XCTAssertEqual(unreadCount2After, unreadCount2Before, "Excluded account must not be checked by checkAllMail")

        // Notification for acc1 should be emitted, but NOT for excluded acc2
        XCTAssertEqual(capturedNotifications.count, 1)
        XCTAssertEqual(capturedNotifications.first, .accountUnread(account: acc1, count: 3))

        // Call checkMail(accountID:) directly for acc2 - should check acc2 even if excluded from global check
        capturedNotifications.removeAll()
        await engine.checkMail(accountID: acc2ID)

        let unreadCount2Final = await fakeClient2.fetchUnreadCountCallCount
        XCTAssertGreaterThan(unreadCount2Final, unreadCount2After, "Direct checkMail must check acc2 even if excluded from global check")
        XCTAssertEqual(capturedNotifications.count, 1)
        XCTAssertEqual(capturedNotifications.first, .accountUnread(account: acc2, count: 5))

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

    @MainActor
    func testCheckAllMailZeroUnreadAcrossAllAccounts() async throws {
        let manager = AccountManager(accountStore: testStore, keychainService: mockKeychain)
        let acc1 = try manager.addAccount(email: "acc1@gmail.com", provider: .gmail, appPassword: "pwd")
        _ = try manager.addAccount(email: "acc2@fastmail.com", provider: .fastmail, appPassword: "pwd")

        let fakeClient1 = FakeIMAPClient()
        let fakeClient2 = FakeIMAPClient()
        await fakeClient1.setUnreadCount(0)
        await fakeClient2.setUnreadCount(0)

        let syncStore = self.syncStore!
        let acc1ID = acc1.id

        let engine = SyncEngine(
            accountManager: manager,
            workerFactory: { account, onNewMail in
                let client = account.id == acc1ID ? fakeClient1 : fakeClient2
                return AccountSyncWorker(
                    account: account,
                    imapClient: client,
                    manualCheckClientFactory: { client },
                    syncStateStore: syncStore,
                    passwordProvider: { _ in "pwd" },
                    sleepProvider: { _ in try await Task.sleep(nanoseconds: 60_000_000_000) },
                    onNewMail: onNewMail
                )
            }
        )

        var notifications: [ManualCheckNotification] = []
        engine.onManualCheckNotification = { notifications.append($0) }

        engine.start()

        await engine.checkAllMail()

        XCTAssertEqual(notifications, [.zeroUnread])
        let client1Calls = await fakeClient1.fetchUnreadCountCallCount
        let client2Calls = await fakeClient2.fetchUnreadCountCallCount
        XCTAssertGreaterThanOrEqual(client1Calls, 1)
        XCTAssertGreaterThanOrEqual(client2Calls, 1)

        engine.stop()
    }

    @MainActor
    func testCheckAllMailMixedUnreadAndZeroAccounts() async throws {
        let manager = AccountManager(accountStore: testStore, keychainService: mockKeychain)
        let acc1 = try manager.addAccount(email: "unread@gmail.com", provider: .gmail, appPassword: "pwd")
        _ = try manager.addAccount(email: "zero@fastmail.com", provider: .fastmail, appPassword: "pwd")

        let fakeClient1 = FakeIMAPClient()
        let fakeClient2 = FakeIMAPClient()
        await fakeClient1.setUnreadCount(4)
        await fakeClient2.setUnreadCount(0)

        let syncStore = self.syncStore!
        let acc1ID = acc1.id

        let engine = SyncEngine(
            accountManager: manager,
            workerFactory: { account, onNewMail in
                let client = account.id == acc1ID ? fakeClient1 : fakeClient2
                return AccountSyncWorker(
                    account: account,
                    imapClient: client,
                    manualCheckClientFactory: { client },
                    syncStateStore: syncStore,
                    passwordProvider: { _ in "pwd" },
                    sleepProvider: { _ in try await Task.sleep(nanoseconds: 60_000_000_000) },
                    onNewMail: onNewMail
                )
            }
        )

        var notifications: [ManualCheckNotification] = []
        engine.onManualCheckNotification = { notifications.append($0) }

        engine.start()

        await engine.checkAllMail()

        // Exactly one notification for acc1 with unread mail; acc2 with 0 is skipped
        XCTAssertEqual(notifications.count, 1)
        XCTAssertEqual(notifications.first, .accountUnread(account: acc1, count: 4))

        engine.stop()
    }

    @MainActor
    func testCheckAllMailMultipleAccountsWithUnreadMail() async throws {
        let manager = AccountManager(accountStore: testStore, keychainService: mockKeychain)
        let acc1 = try manager.addAccount(email: "acc1@gmail.com", provider: .gmail, appPassword: "pwd")
        let acc2 = try manager.addAccount(email: "acc2@fastmail.com", provider: .fastmail, appPassword: "pwd")

        let fakeClient1 = FakeIMAPClient()
        let fakeClient2 = FakeIMAPClient()
        await fakeClient1.setUnreadCount(2)
        await fakeClient2.setUnreadCount(5)

        let syncStore = self.syncStore!
        let acc1ID = acc1.id

        let engine = SyncEngine(
            accountManager: manager,
            workerFactory: { account, onNewMail in
                let client = account.id == acc1ID ? fakeClient1 : fakeClient2
                return AccountSyncWorker(
                    account: account,
                    imapClient: client,
                    manualCheckClientFactory: { client },
                    syncStateStore: syncStore,
                    passwordProvider: { _ in "pwd" },
                    sleepProvider: { _ in try await Task.sleep(nanoseconds: 60_000_000_000) },
                    onNewMail: onNewMail
                )
            }
        )

        var notifications: [ManualCheckNotification] = []
        engine.onManualCheckNotification = { notifications.append($0) }

        engine.start()

        await engine.checkAllMail()

        // One notification per account with unread mail
        XCTAssertEqual(notifications.count, 2)
        XCTAssertTrue(notifications.contains(.accountUnread(account: acc1, count: 2)))
        XCTAssertTrue(notifications.contains(.accountUnread(account: acc2, count: 5)))

        engine.stop()
    }

    @MainActor
    func testCheckMailSingleAccountZeroUnread() async throws {
        let manager = AccountManager(accountStore: testStore, keychainService: mockKeychain)
        let acc1 = try manager.addAccount(email: "single-zero@gmail.com", provider: .gmail, appPassword: "pwd")

        let fakeClient = FakeIMAPClient()
        await fakeClient.setUnreadCount(0)

        let syncStore = self.syncStore!

        let engine = SyncEngine(
            accountManager: manager,
            workerFactory: { account, onNewMail in
                AccountSyncWorker(
                    account: account,
                    imapClient: fakeClient,
                    manualCheckClientFactory: { fakeClient },
                    syncStateStore: syncStore,
                    passwordProvider: { _ in "pwd" },
                    sleepProvider: { _ in try await Task.sleep(nanoseconds: 60_000_000_000) },
                    onNewMail: onNewMail
                )
            }
        )

        var notifications: [ManualCheckNotification] = []
        engine.onManualCheckNotification = { notifications.append($0) }

        engine.start()

        await engine.checkMail(accountID: acc1.id)

        XCTAssertEqual(notifications, [.zeroUnread])

        engine.stop()
    }

    @MainActor
    func testCheckMailSingleAccountWithUnreadMail() async throws {
        let manager = AccountManager(accountStore: testStore, keychainService: mockKeychain)
        let acc1 = try manager.addAccount(email: "single-unread@gmail.com", provider: .gmail, appPassword: "pwd")

        let fakeClient = FakeIMAPClient()
        await fakeClient.setUnreadCount(11)

        let syncStore = self.syncStore!

        let engine = SyncEngine(
            accountManager: manager,
            workerFactory: { account, onNewMail in
                AccountSyncWorker(
                    account: account,
                    imapClient: fakeClient,
                    manualCheckClientFactory: { fakeClient },
                    syncStateStore: syncStore,
                    passwordProvider: { _ in "pwd" },
                    sleepProvider: { _ in try await Task.sleep(nanoseconds: 60_000_000_000) },
                    onNewMail: onNewMail
                )
            }
        )

        var notifications: [ManualCheckNotification] = []
        engine.onManualCheckNotification = { notifications.append($0) }

        engine.start()

        await engine.checkMail(accountID: acc1.id)

        XCTAssertEqual(notifications, [.accountUnread(account: acc1, count: 11)])

        engine.stop()
    }

    // MARK: - Restart behaviour

    @MainActor
    func testChangingDefaultFrequencyRestartsWorkersThatUseTheDefault() async throws {
        let defaults = UserDefaults(suiteName: "ding-engine-tests-\(UUID().uuidString)")!
        let prefs = AppPreferences(userDefaults: defaults)
        let manager = AccountManager(accountStore: testStore, keychainService: mockKeychain)
        _ = try manager.addAccount(email: "default@gmail.com", provider: .gmail, appPassword: "pwd")
        _ = try manager.addAccount(email: "explicit@fastmail.com", provider: .fastmail, appPassword: "pwd")
        var explicit = manager.accounts[1]
        explicit.syncFrequency = .oneMinute
        try manager.updateAccount(explicit)

        let created = LockProtected<[String]>([])
        let syncStore = self.syncStore!
        let engine = SyncEngine(
            accountManager: manager,
            appPreferences: prefs,
            workerFactory: { account, onNewMail in
                created.withLock { $0.append(account.email) }
                let client = FakeIMAPClient()
                return AccountSyncWorker(
                    account: account,
                    imapClient: client,
                    manualCheckClientFactory: { client },
                    syncStateStore: syncStore,
                    passwordProvider: { _ in "pwd" },
                    sleepProvider: { _ in try await Task.sleep(nanoseconds: 10_000_000) },
                    onNewMail: onNewMail
                )
            }
        )

        engine.start()
        XCTAssertEqual(created.get().count, 2)

        prefs.defaultSyncFrequency = .fifteenMinutes

        for _ in 0..<100 {
            if created.get().count >= 3 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(created.get().filter { $0 == "default@gmail.com" }.count, 2, "Worker following the default must be recreated")
        XCTAssertEqual(created.get().filter { $0 == "explicit@fastmail.com" }.count, 1, "Worker with an explicit frequency must be left alone")
        engine.stop()
    }

    @MainActor
    func testClearingReauthenticationFlagRestartsHaltedWorker() async throws {
        let manager = AccountManager(accountStore: testStore, keychainService: mockKeychain)
        let account = try manager.addAccount(email: "reauth@gmail.com", provider: .gmail, appPassword: "pwd")
        try manager.setNeedsReauthentication(forAccountID: account.id, needsReauthentication: true)

        let created = LockProtected<Int>(0)
        let firstClient = FakeIMAPClient(loginError: .authenticationFailed)
        let syncStore = self.syncStore!
        let engine = SyncEngine(
            accountManager: manager,
            workerFactory: { account, onNewMail in
                let attempt = created.withLock { value -> Int in value += 1; return value }
                // The first worker is rejected by the server and halts; later ones succeed.
                let client = attempt == 1 ? firstClient : FakeIMAPClient()
                return AccountSyncWorker(
                    account: account,
                    imapClient: client,
                    manualCheckClientFactory: { client },
                    syncStateStore: syncStore,
                    passwordProvider: { _ in "pwd" },
                    reauthenticationHandler: { _ in },
                    sleepProvider: { _ in try await Task.sleep(nanoseconds: 10_000_000) },
                    onNewMail: onNewMail
                )
            }
        )

        engine.start()
        let firstWorker = try XCTUnwrap(engine.workers[account.id])
        for _ in 0..<100 {
            if await firstClient.loginCallCount > 0, await !firstWorker.active { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let halted = await !firstWorker.active
        XCTAssertTrue(halted, "Precondition: an auth failure must halt the worker")

        try manager.updatePassword(forAccountID: account.id, newPassword: "new-password")
        try manager.setNeedsReauthentication(forAccountID: account.id, needsReauthentication: false)

        for _ in 0..<100 {
            if created.get() >= 2 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(created.get(), 2, "Re-authenticating must replace the halted worker")
        engine.stop()
    }

    @MainActor
    func testClearingReauthenticationFlagLeavesRunningWorkerAlone() async throws {
        let manager = AccountManager(accountStore: testStore, keychainService: mockKeychain)
        let account = try manager.addAccount(email: "healthy@gmail.com", provider: .gmail, appPassword: "pwd")
        try manager.setNeedsReauthentication(forAccountID: account.id, needsReauthentication: true)

        let created = LockProtected<Int>(0)
        let syncStore = self.syncStore!
        let engine = SyncEngine(
            accountManager: manager,
            workerFactory: { account, onNewMail in
                created.withLock { $0 += 1 }
                let client = FakeIMAPClient()
                return AccountSyncWorker(
                    account: account,
                    imapClient: client,
                    manualCheckClientFactory: { client },
                    syncStateStore: syncStore,
                    passwordProvider: { _ in "pwd" },
                    authenticationRecoveredHandler: { _ in },
                    sleepProvider: { _ in try await Task.sleep(nanoseconds: 60_000_000_000) },
                    onNewMail: onNewMail
                )
            }
        )

        engine.start()
        try await Task.sleep(nanoseconds: 100_000_000)
        try manager.setNeedsReauthentication(forAccountID: account.id, needsReauthentication: false)
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(created.get(), 1, "A worker that is still running must not be restarted")
        engine.stop()
    }

    @MainActor
    func testAccountsNeedingAttentionListsOnlyFlaggedAccounts() throws {
        let manager = AccountManager(accountStore: testStore, keychainService: mockKeychain)
        let ok = try manager.addAccount(email: "ok@gmail.com", provider: .gmail, appPassword: "pwd")
        let bad = try manager.addAccount(email: "bad@gmail.com", provider: .gmail, appPassword: "pwd")
        let engine = SyncEngine(accountManager: manager, workerFactory: { account, onNewMail in
            AccountSyncWorker(account: account, imapClient: FakeIMAPClient(), manualCheckClientFactory: { FakeIMAPClient() }, onNewMail: onNewMail)
        })

        XCTAssertTrue(engine.accountsNeedingAttention.isEmpty)
        try manager.setNeedsReauthentication(forAccountID: bad.id, needsReauthentication: true)
        XCTAssertEqual(engine.accountsNeedingAttention.map(\.id), [bad.id])
        XCTAssertFalse(engine.accountsNeedingAttention.contains { $0.id == ok.id })
    }

    @MainActor
    func testCheckAllMailWithOneFailureDoesNotClaimZeroUnread() async throws {
        let manager = AccountManager(accountStore: testStore, keychainService: mockKeychain)
        _ = try manager.addAccount(email: "works@gmail.com", provider: .gmail, appPassword: "pwd")
        _ = try manager.addAccount(email: "offline@fastmail.com", provider: .fastmail, appPassword: "pwd")

        let syncStore = self.syncStore!
        let engine = SyncEngine(
            accountManager: manager,
            workerFactory: { account, onNewMail in
                let client = FakeIMAPClient()
                let isBroken = account.email.contains("offline")
                return AccountSyncWorker(
                    account: account,
                    imapClient: client,
                    manualCheckClientFactory: {
                        isBroken ? FakeIMAPClient(connectError: .connectionFailed(underlying: NSError(domain: "net", code: -1009))) : FakeIMAPClient()
                    },
                    syncStateStore: syncStore,
                    passwordProvider: { _ in "pwd" },
                    sleepProvider: { _ in try await Task.sleep(nanoseconds: 60_000_000_000) },
                    onNewMail: onNewMail
                )
            }
        )
        var notifications: [ManualCheckNotification] = []
        engine.onManualCheckNotification = { notifications.append($0) }

        engine.start()
        await engine.checkAllMail()
        engine.stop()

        XCTAssertFalse(notifications.contains(.zeroUnread), "An unchecked account means the inbox state is unknown")
        XCTAssertEqual(notifications, [.checkFailed(accountCount: 1)])
    }

    @MainActor
    func testSingleAccountCheckFailureIsReported() async throws {
        let manager = AccountManager(accountStore: testStore, keychainService: mockKeychain)
        let account = try manager.addAccount(email: "down@gmail.com", provider: .gmail, appPassword: "pwd")
        let syncStore = self.syncStore!
        let engine = SyncEngine(
            accountManager: manager,
            workerFactory: { account, onNewMail in
                AccountSyncWorker(
                    account: account,
                    imapClient: FakeIMAPClient(),
                    manualCheckClientFactory: { FakeIMAPClient(connectError: .timeout) },
                    syncStateStore: syncStore,
                    passwordProvider: { _ in "pwd" },
                    sleepProvider: { _ in try await Task.sleep(nanoseconds: 60_000_000_000) },
                    onNewMail: onNewMail
                )
            }
        )
        var notifications: [ManualCheckNotification] = []
        engine.onManualCheckNotification = { notifications.append($0) }

        engine.start()
        await engine.checkMail(accountID: account.id)
        engine.stop()

        XCTAssertEqual(notifications, [.checkFailed(accountCount: 1)])
    }

    // MARK: - Account health

    /// Waits for a main-actor condition with a deadline rather than a fixed sleep.
    @MainActor
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    @MainActor
    func testRestartedWorkerKeepsPreviousLastSuccessfulCheck() async throws {
        let manager = AccountManager(accountStore: testStore, keychainService: mockKeychain)
        let account = try manager.addAccount(email: "restart@gmail.com", provider: .gmail, appPassword: "pwd")
        let syncStore = self.syncStore!
        let firstCheck = Date(timeIntervalSince1970: 1_800_000_000)

        let healthyClient = FakeIMAPClient()
        let failingClient = FakeIMAPClient(connectError: .timeout)
        let creations = LockProtected<Int>(0)

        let engine = SyncEngine(
            accountManager: manager,
            workerFactory: { account, onNewMail in
                let isFirst = creations.withLock { count -> Bool in count += 1; return count == 1 }
                let client = isFirst ? healthyClient : failingClient
                return AccountSyncWorker(
                    account: account,
                    imapClient: client,
                    manualCheckClientFactory: { client },
                    syncStateStore: syncStore,
                    defaultSyncFrequency: .fiveMinutes,
                    passwordProvider: { _ in "pwd" },
                    sleepProvider: { _ in try await Task.sleep(nanoseconds: 5_000_000) },
                    backoffJitter: { 0 },
                    onNewMail: onNewMail,
                    now: { firstCheck }
                )
            }
        )
        engine.start()
        defer { engine.stop() }

        let recorded = try await waitUntil { engine.accountHealth[account.id]?.lastSuccessfulCheck == firstCheck }
        XCTAssertTrue(recorded)

        var changed = account
        changed.syncFrequency = .fifteenMinutes
        try manager.updateAccount(changed)

        let restarted = try await waitUntil { (engine.accountHealth[account.id]?.consecutiveFailures ?? 0) > 0 }
        XCTAssertTrue(restarted, "The replacement worker should have reported its failures")
        XCTAssertEqual(
            engine.accountHealth[account.id]?.lastSuccessfulCheck, firstCheck,
            "A restart must not erase the history of the last successful check"
        )
    }

    @MainActor
    func testRemovingAccountClearsItsHealth() async throws {
        let manager = AccountManager(accountStore: testStore, keychainService: mockKeychain)
        let account = try manager.addAccount(email: "gone@gmail.com", provider: .gmail, appPassword: "pwd")
        let syncStore = self.syncStore!

        let engine = SyncEngine(
            accountManager: manager,
            workerFactory: { account, onNewMail in
                AccountSyncWorker(
                    account: account,
                    imapClient: FakeIMAPClient(),
                    manualCheckClientFactory: { FakeIMAPClient() },
                    syncStateStore: syncStore,
                    defaultSyncFrequency: .fiveMinutes,
                    passwordProvider: { _ in "pwd" },
                    sleepProvider: { _ in try await Task.sleep(nanoseconds: 5_000_000) },
                    onNewMail: onNewMail
                )
            }
        )
        engine.start()
        defer { engine.stop() }

        let seen = try await waitUntil { engine.accountHealth[account.id] != nil }
        XCTAssertTrue(seen)

        try manager.removeAccount(id: account.id)
        XCTAssertNil(engine.accountHealth[account.id])

        // A late snapshot from the removed worker must not bring the entry back.
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(engine.accountHealth[account.id])
    }

    @MainActor
    func testStopClearsHealth() async throws {
        let manager = AccountManager(accountStore: testStore, keychainService: mockKeychain)
        let account = try manager.addAccount(email: "stop@gmail.com", provider: .gmail, appPassword: "pwd")
        let syncStore = self.syncStore!

        let engine = SyncEngine(
            accountManager: manager,
            workerFactory: { account, onNewMail in
                AccountSyncWorker(
                    account: account,
                    imapClient: FakeIMAPClient(),
                    manualCheckClientFactory: { FakeIMAPClient() },
                    syncStateStore: syncStore,
                    defaultSyncFrequency: .fiveMinutes,
                    passwordProvider: { _ in "pwd" },
                    sleepProvider: { _ in try await Task.sleep(nanoseconds: 5_000_000) },
                    onNewMail: onNewMail
                )
            }
        )
        engine.start()
        let seen = try await waitUntil { engine.accountHealth[account.id] != nil }
        XCTAssertTrue(seen)

        engine.stop()
        XCTAssertTrue(engine.accountHealth.isEmpty)
    }

    @MainActor
    func testConnectionProblemsAreHiddenWhileOffline() async throws {
        let manager = AccountManager(accountStore: testStore, keychainService: mockKeychain)
        let failing = try manager.addAccount(email: "down@gmail.com", provider: .gmail, appPassword: "pwd")
        let flagged = try manager.addAccount(email: "flagged@gmail.com", provider: .gmail, appPassword: "pwd")
        try manager.setNeedsReauthentication(forAccountID: flagged.id, needsReauthentication: true)
        let syncStore = self.syncStore!
        let monitor = ConnectivityMonitor(debounce: .milliseconds(20))

        let engine = SyncEngine(
            accountManager: manager,
            connectivityMonitor: monitor,
            workerFactory: { account, onNewMail in
                let client = FakeIMAPClient(connectError: .timeout)
                return AccountSyncWorker(
                    account: account,
                    imapClient: client,
                    manualCheckClientFactory: { client },
                    syncStateStore: syncStore,
                    defaultSyncFrequency: .fiveMinutes,
                    passwordProvider: { _ in "pwd" },
                    sleepProvider: { _ in try await Task.sleep(nanoseconds: 5_000_000) },
                    backoffJitter: { 0 },
                    onNewMail: onNewMail
                )
            }
        )
        engine.start()
        defer { engine.stop() }
        // Silence the real path monitor so only the updates below drive availability.
        monitor.stop()
        try await Task.sleep(nanoseconds: 100_000_000)
        monitor.onNetworkAvailabilityChanged?(true)

        let degraded = try await waitUntil { engine.accountsWithConnectionProblems.contains { $0.id == failing.id } }
        XCTAssertTrue(degraded)
        XCTAssertEqual(engine.allAccounts.count, 2)
        XCTAssertFalse(
            engine.accountsWithConnectionProblems.contains { $0.id == flagged.id },
            "An account awaiting a password has its own prompt"
        )

        monitor.handlePathUpdate(status: .unsatisfied)
        XCTAssertFalse(engine.isNetworkAvailable)
        XCTAssertTrue(engine.accountsWithConnectionProblems.isEmpty, "While offline, only the Offline state is shown")

        monitor.handlePathUpdate(status: .satisfied)
        XCTAssertTrue(engine.isNetworkAvailable)
        XCTAssertTrue(engine.accountsWithConnectionProblems.contains { $0.id == failing.id })
    }

    // MARK: - Sustained-failure notification

    @MainActor
    private final class TestClock {
        var date = Date(timeIntervalSince1970: 1_800_000_000)
    }

    /// An engine with one account whose fake server is healthy until the test makes it fail, plus the means to
    /// drive network availability and time deterministically.
    @MainActor
    private func makeFailureHarness() async throws -> (
        engine: SyncEngine, client: FakeIMAPClient, monitor: ConnectivityMonitor, clock: TestClock,
        account: Account, notified: LockProtected<Int>
    ) {
        let manager = AccountManager(accountStore: testStore, keychainService: mockKeychain)
        let account = try manager.addAccount(email: "outage@gmail.com", provider: .gmail, appPassword: "pwd")
        let syncStore = self.syncStore!
        let client = FakeIMAPClient()
        let monitor = ConnectivityMonitor(debounce: .milliseconds(20))
        let clock = TestClock()
        let notified = LockProtected<Int>(0)

        let engine = SyncEngine(
            accountManager: manager,
            connectivityMonitor: monitor,
            workerFactory: { account, onNewMail in
                AccountSyncWorker(
                    account: account,
                    imapClient: client,
                    manualCheckClientFactory: { client },
                    syncStateStore: syncStore,
                    defaultSyncFrequency: .fiveMinutes,
                    passwordProvider: { _ in "pwd" },
                    sleepProvider: { _ in try await Task.sleep(nanoseconds: 3_000_000) },
                    backoffJitter: { 0 },
                    onNewMail: onNewMail
                )
            },
            now: { clock.date }
        )
        engine.onConnectionProblemNotification = { _ in notified.withLock { $0 += 1 } }
        engine.start()
        // Silence the real path monitor so only the updates a test sends drive availability.
        monitor.stop()
        try await Task.sleep(nanoseconds: 100_000_000)
        monitor.handlePathUpdate(status: .satisfied)

        let healthy = try await waitUntil { engine.accountHealth[account.id]?.lastSuccessfulCheck != nil }
        XCTAssertTrue(healthy)
        return (engine, client, monitor, clock, account, notified)
    }

    @MainActor
    func testSustainedFailureNotifiesOncePerOutage() async throws {
        let h = try await makeFailureHarness()
        defer { h.engine.stop() }

        await h.client.setConnectError(.timeout)
        let threshold = AccountHealth.notificationThreshold
        let fired = try await waitUntil { h.notified.get() == 1 }
        XCTAssertTrue(fired)

        // Keep failing well past the threshold: still only one notification.
        let kept = try await waitUntil { (h.engine.accountHealth[h.account.id]?.consecutiveFailures ?? 0) >= threshold + 6 }
        XCTAssertTrue(kept)
        XCTAssertEqual(h.notified.get(), 1)
    }

    @MainActor
    func testNotificationRearmsAfterRecovery() async throws {
        let h = try await makeFailureHarness()
        defer { h.engine.stop() }

        await h.client.setConnectError(.timeout)
        let first = try await waitUntil { h.notified.get() == 1 }
        XCTAssertTrue(first)

        await h.client.setConnectError(nil)
        let recovered = try await waitUntil { h.engine.accountHealth[h.account.id]?.consecutiveFailures == 0 }
        XCTAssertTrue(recovered)

        await h.client.setConnectError(.timeout)
        let second = try await waitUntil { h.notified.get() == 2 }
        XCTAssertTrue(second, "A new outage after recovery should notify again")
    }

    @MainActor
    func testNotificationSuppressedWhileOfflineAndDuringGracePeriod() async throws {
        let h = try await makeFailureHarness()
        defer { h.engine.stop() }
        let threshold = AccountHealth.notificationThreshold

        h.monitor.handlePathUpdate(status: .unsatisfied)
        await h.client.setConnectError(.timeout)
        let failedOffline = try await waitUntil { (h.engine.accountHealth[h.account.id]?.consecutiveFailures ?? 0) >= threshold + 2 }
        XCTAssertTrue(failedOffline)
        XCTAssertEqual(h.notified.get(), 0, "Failures while offline are explained by being offline")

        // The network returns, but the workers have not had time to reconnect yet.
        h.monitor.handlePathUpdate(status: .satisfied)
        let stillFailing = try await waitUntil { (h.engine.accountHealth[h.account.id]?.consecutiveFailures ?? 0) >= threshold + 8 }
        XCTAssertTrue(stillFailing)
        XCTAssertEqual(h.notified.get(), 0, "The grace period after the network returns must stay quiet")

        // Past the grace period, a persistent failure is a real problem.
        h.clock.date = h.clock.date.addingTimeInterval(6 * 60)
        let fired = try await waitUntil { h.notified.get() == 1 }
        XCTAssertTrue(fired)
    }
}
