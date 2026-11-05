import Combine
import Foundation
import KeyboardShortcuts
import os

/// Types of notifications generated as a result of manual mail checking.
public enum ManualCheckNotification: Equatable, Sendable {
    /// Zero unread emails detected across checked accounts.
    case zeroUnread

    /// Positive unread email count detected for a specific account.
    case accountUnread(account: Account, count: Int)

    /// One or more accounts could not be checked (offline, server error, rejected credentials).
    case checkFailed(accountCount: Int)
}

/// The top-level coordinator managing per-account synchronization workers.
///
/// ## Concurrency & Actor Isolation Architecture
/// Ding's synchronization architecture is partitioned into two distinct concurrency layers:
///
/// 1. **Coordination Layer (`@MainActor` / `ObservableObject`)**:
///    `SyncEngine` is bound to `@MainActor` and conforms to `ObservableObject`. This aligns seamlessly
///    with `AccountManager`, `AppPreferences`, SwiftUI settings views, and `AppDelegate`, ensuring that
///    account lifecycle notifications and preference updates are received and coordinated on the main thread
///    without data races or thread hop overhead.
///
/// 2. **Execution Layer (`actor AccountSyncWorker`)**:
///    Each individual account's synchronization lifecycle is isolated inside its own `AccountSyncWorker` actor.
///    Network I/O, socket reading, IDLE event handling, and exponential backoff timing run concurrently
///    in background tasks, preventing network delays or stalls on one account from blocking other accounts
///    or freezing the main application UI.
@MainActor
public final class SyncEngine: ObservableObject {
    nonisolated private static let logger = Logger(subsystem: DingLog.subsystem, category: "SyncEngine")

    /// The shared singleton instance of `SyncEngine`.
    public static let shared = SyncEngine()

    /// Factory type responsible for constructing `AccountSyncWorker` instances (injectable for unit testing).
    public typealias WorkerFactory = @MainActor @Sendable (Account, @escaping @Sendable (NewMailEvent) -> Void) -> AccountSyncWorker

    /// Callback invoked whenever any managed account worker detects new mail.
    public var onNewMailDetected: ((NewMailEvent) -> Void)?

    /// Callback invoked when an account has been unreachable long enough to notify the user (injectable for unit testing).
    public var onConnectionProblemNotification: ((Account) -> Void)?

    /// Callback invoked whenever a manual mail check produces a notification (injectable for unit testing).
    public var onManualCheckNotification: ((ManualCheckNotification) -> Void)?

    /// Currently active workers keyed by `Account.id`.
    public private(set) var workers: [UUID: AccountSyncWorker] = [:]

    /// Indicates whether the sync engine is active.
    @Published public private(set) var isRunning: Bool = false

    /// The latest health of each account's worker. In memory only; a restarted worker keeps its predecessor's
    /// `lastSuccessfulCheck` until it records one of its own.
    @Published public private(set) var accountHealth: [UUID: AccountHealth] = [:]

    /// Whether the network is currently usable, as last reported by the connectivity monitor.
    @Published public private(set) var isNetworkAvailable: Bool = true

    /// Accounts whose credentials were rejected and that need a new app password before syncing can resume.
    public var accountsNeedingAttention: [Account] {
        accountManager.accounts.filter { $0.needsReauthentication }
    }

    /// Every configured account, including those excluded from manual checks.
    public var allAccounts: [Account] {
        accountManager.accounts
    }

    /// Accounts that could not connect for long enough to warrant a warning.
    ///
    /// Empty while the network is down, since "offline" explains every failure and is shown on its own. Accounts
    /// awaiting a new password are excluded because they have their own, more specific prompt.
    public var accountsWithConnectionProblems: [Account] {
        guard isNetworkAvailable else { return [] }
        return accountManager.accounts.filter { account in
            !account.needsReauthentication && accountHealth[account.id]?.isDegraded == true
        }
    }

    /// The list of configured accounts that have manual checking enabled.
    public var manualCheckAccounts: [Account] {
        accountManager.accounts.filter { $0.includeInManualCheck }
    }

    private let accountManager: AccountManager
    private let appPreferences: AppPreferences
    private let notificationService: NotificationService
    private let workerFactory: WorkerFactory
    private let connectivityMonitor: ConnectivityMonitor
    private var cancellables = Set<AnyCancellable>()
    private var accountObservation: AnyCancellable?
    private var eventContinuations: [UUID: AsyncStream<NewMailEvent>.Continuation] = [:]
    private var registeredShortcutAccountIDs = Set<UUID>()
    private var restartTasks: [UUID: Task<Void, Never>] = [:]
    private var healthTasks: [UUID: Task<Void, Never>] = [:]
    private let now: @MainActor () -> Date

    /// Accounts already notified about their current outage; re-armed when the account recovers.
    private var connectionProblemNotified = Set<UUID>()

    /// When the network last came back, so failures that built up while offline don't raise a false alarm
    /// before the workers have had time to reconnect.
    private var lastNetworkRestoredAt: Date?

    /// How long after the network returns before a connection-problem notification may fire.
    private static let networkRestoredGracePeriod: TimeInterval = 5 * 60

    /// The global default frequency as last observed. Tracked here (rather than re-read from `appPreferences`)
    /// because `@Published` publishes in `willSet`, before the stored property holds the new value.
    private var currentDefaultFrequency: SyncFrequency

    /// The effective frequency each live worker was created with, used to detect when a restart is needed.
    private var resolvedFrequencies: [UUID: SyncFrequency] = [:]

    /// The last observed `needsReauthentication` flag per account, used to detect a re-authentication.
    private var lastReauthFlags: [UUID: Bool] = [:]

    /// Initializes a new sync engine coordinator.
    ///
    /// - Parameters:
    ///   - accountManager: Account store manager to observe. Defaults to `AccountManager.shared`.
    ///   - appPreferences: Global preferences store. Defaults to `AppPreferences.shared`.
    ///   - notificationService: Notification delivery service. Defaults to `NotificationService.shared`.
    ///   - connectivityMonitor: Sleep/wake and network change detector. Defaults to a live monitor.
    ///   - workerFactory: Factory closure for generating account workers (injected in unit tests).
    ///   - now: Supplies the current time for the connection-problem grace period (injected in unit tests).
    init(
        accountManager: AccountManager = .shared,
        appPreferences: AppPreferences = .shared,
        notificationService: NotificationService = .shared,
        connectivityMonitor: ConnectivityMonitor? = nil,
        workerFactory: WorkerFactory? = nil,
        now: (@MainActor () -> Date)? = nil
    ) {
        self.now = now ?? { Date() }
        self.connectivityMonitor = connectivityMonitor ?? ConnectivityMonitor()
        self.accountManager = accountManager
        self.appPreferences = appPreferences
        self.notificationService = notificationService
        self.currentDefaultFrequency = appPreferences.defaultSyncFrequency

        self.workerFactory = workerFactory ?? { [appPreferences] account, onNewMail in
            // Read at creation time so workers started after a settings change use the current default.
            AccountSyncWorker(
                account: account,
                defaultSyncFrequency: appPreferences.defaultSyncFrequency,
                onNewMail: onNewMail
            )
        }

        self.accountObservation = accountManager.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /// Starts the sync engine, spinning up workers for all currently configured accounts and observing changes.
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        Self.logger.info("Starting SyncEngine with \(self.accountManager.accounts.count, privacy: .public) account(s)")

        // Reconnect promptly after sleep or a network change
        connectivityMonitor.onReconnectNeeded = { [weak self] in
            self?.reconnectAllWorkers()
        }
        connectivityMonitor.onNetworkAvailabilityChanged = { [weak self] isAvailable in
            self?.setNetworkAvailable(isAvailable)
        }
        connectivityMonitor.start()

        // Register global shortcut listener
        KeyboardShortcuts.onKeyUp(for: .checkAllMail) { [weak self] in
            Task { @MainActor [weak self] in
                await self?.checkAllMail()
            }
        }

        // Synchronize initial workers and account shortcuts
        syncWorkers(with: accountManager.accounts)

        // Observe account changes dynamically
        accountManager.$accounts
            .dropFirst()
            .sink { [weak self] updatedAccounts in
                self?.syncWorkers(with: updatedAccounts)
            }
            .store(in: &cancellables)

        // Re-evaluate workers when the global default frequency changes
        appPreferences.$defaultSyncFrequency
            .dropFirst()
            .sink { [weak self] newDefault in
                guard let self else { return }
                self.currentDefaultFrequency = newDefault
                self.syncWorkers(with: self.accountManager.accounts)
            }
            .store(in: &cancellables)
    }

    /// Stops all account sync workers and cancels subscriptions.
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        Self.logger.info("Stopping SyncEngine and all child workers")

        cancellables.removeAll()
        connectivityMonitor.stop()

        KeyboardShortcuts.disable(.checkAllMail)
        KeyboardShortcuts.removeHandler(for: .checkAllMail)
        for id in registeredShortcutAccountIDs {
            KeyboardShortcuts.disable(.checkMail(accountID: id))
            KeyboardShortcuts.removeHandler(for: .checkMail(accountID: id))
        }
        registeredShortcutAccountIDs.removeAll()

        for (_, task) in restartTasks {
            task.cancel()
        }
        restartTasks.removeAll()

        for (id, worker) in workers {
            Task {
                await worker.stop()
            }
            Self.logger.debug("Tore down worker for account: \(id.uuidString, privacy: .public)")
        }
        workers.removeAll()
        for (_, task) in healthTasks {
            task.cancel()
        }
        healthTasks.removeAll()
        accountHealth.removeAll()
        connectionProblemNotified.removeAll()
        resolvedFrequencies.removeAll()
        lastReauthFlags.removeAll()

        for continuation in eventContinuations.values {
            continuation.finish()
        }
        eventContinuations.removeAll()
    }

    /// Subscribes to a stream of all new mail events emitted across all configured accounts.
    public func newMailStream() -> AsyncStream<NewMailEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            eventContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.eventContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    /// Asks every worker to drop its connection and reconnect immediately.
    func reconnectAllWorkers() {
        Self.logger.info("Reconnecting \(self.workers.count, privacy: .public) worker(s) after wake or network change")
        for worker in workers.values {
            Task {
                await worker.reconnectNow()
            }
        }
    }

    // MARK: - Manual Mail Checking

    /// Forces an immediate manual check for unread mail on a specific account.
    ///
    /// If zero unread emails are found, delivers a single "You have 0 unread emails" notification.
    /// If unread emails are found, delivers a notification specifying that account's unread count.
    ///
    /// - Parameter accountID: The unique identifier of the account to check.
    public func checkMail(accountID: UUID) async {
        guard let worker = workers[accountID] else {
            Self.logger.warning("Attempted to check mail for unregistered account: \(accountID.uuidString, privacy: .public)")
            return
        }
        guard let account = accountManager.accounts.first(where: { $0.id == accountID }) else {
            Self.logger.warning("Account model not found for unregistered account: \(accountID.uuidString, privacy: .public)")
            return
        }

        Self.logger.info("Triggering manual mail check for account: \(accountID.uuidString, privacy: .public)")
        do {
            let count = try await worker.checkUnreadCount()
            if count == 0 {
                await deliverZeroUnreadNotification()
            } else {
                await deliverAccountUnreadNotification(account: account, count: count)
            }
        } catch {
            Self.logger.error("Failed to check unread count for account \(accountID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .private)")
            await deliverCheckFailedNotification(failedCount: 1)
        }
    }

    /// Forces an immediate manual check for unread mail concurrently across all accounts configured to participate in manual checks.
    ///
    /// If total unread across all included accounts is 0, delivers a single "You have 0 unread emails" notification.
    /// If any account has unread mail, delivers one notification per account with unread mail (accounts with 0 unread are skipped).
    public func checkAllMail() async {
        let eligibleAccounts = accountManager.accounts.filter { $0.includeInManualCheck }
        Self.logger.info("Triggering manual mail check for \(eligibleAccounts.count, privacy: .public) eligible account(s)")

        guard !eligibleAccounts.isEmpty else {
            Self.logger.info("No eligible accounts configured for manual check; delivering zero-unread notification")
            await deliverZeroUnreadNotification()
            return
        }

        var results: [(account: Account, unreadCount: Int)] = []
        var failedCount = 0

        await withTaskGroup(of: (Account, Int)?.self) { group in
            for account in eligibleAccounts {
                if let worker = self.workers[account.id] {
                    group.addTask {
                        do {
                            let count = try await worker.checkUnreadCount()
                            return (account, count)
                        } catch {
                            Self.logger.error("Failed to check unread count for account \(account.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .private)")
                            return nil
                        }
                    }
                }
            }

            for await result in group {
                if let result = result {
                    results.append(result)
                } else {
                    failedCount += 1
                }
            }
        }

        if failedCount > 0 {
            await deliverCheckFailedNotification(failedCount: failedCount)
        }

        guard !results.isEmpty else {
            Self.logger.warning("All manual check queries failed or yielded no results; skipping unread notifications")
            return
        }

        let totalUnread = results.reduce(0) { $0 + $1.unreadCount }

        if totalUnread == 0 {
            // Only claim an empty inbox when every account was actually checked.
            if failedCount == 0 {
                await deliverZeroUnreadNotification()
            }
        } else {
            for result in results where result.unreadCount > 0 {
                await deliverAccountUnreadNotification(account: result.account, count: result.unreadCount)
            }
        }
    }

    private func deliverZeroUnreadNotification() async {
        Self.logger.info("Delivering zero unread notification")
        onManualCheckNotification?(.zeroUnread)
        await notificationService.sendZeroUnreadNotification()
    }

    private func deliverCheckFailedNotification(failedCount: Int) async {
        Self.logger.info("Delivering check-failed notification for \(failedCount, privacy: .public) account(s)")
        onManualCheckNotification?(.checkFailed(accountCount: failedCount))
        await notificationService.sendCheckFailedNotification(failedCount: failedCount)
    }

    private func deliverAccountUnreadNotification(account: Account, count: Int) async {
        Self.logger.info("Delivering unread notification for account \(account.id.uuidString, privacy: .public): \(count, privacy: .public)")
        onManualCheckNotification?(.accountUnread(account: account, count: count))
        await notificationService.sendAccountUnreadNotification(account: account, unreadCount: count)
    }

    // MARK: - Account Worker Synchronization

    private func effectiveFrequency(for account: Account) -> SyncFrequency {
        account.syncFrequency == .useDefault ? currentDefaultFrequency : account.syncFrequency
    }

    private func syncWorkers(with accounts: [Account]) {
        guard isRunning else { return }
        let currentIDs = Set(accounts.map(\.id))
        let existingIDs = Set(workers.keys)

        // 1. Remove workers for deleted accounts
        let removedIDs = existingIDs.subtracting(currentIDs)
        for id in removedIDs {
            restartTasks.removeValue(forKey: id)?.cancel()
            healthTasks.removeValue(forKey: id)?.cancel()
            accountHealth.removeValue(forKey: id)
            connectionProblemNotified.remove(id)
            resolvedFrequencies.removeValue(forKey: id)
            lastReauthFlags.removeValue(forKey: id)
            if let worker = workers.removeValue(forKey: id) {
                Self.logger.info("Removing worker for deleted account: \(id.uuidString, privacy: .public)")
                Task {
                    await worker.stop()
                }
            }
        }

        let removedShortcutIDs = registeredShortcutAccountIDs.subtracting(currentIDs)
        for id in removedShortcutIDs {
            KeyboardShortcuts.removeHandler(for: .checkMail(accountID: id))
            KeyboardShortcuts.disable(.checkMail(accountID: id))
            KeyboardShortcuts.reset(.checkMail(accountID: id))
            registeredShortcutAccountIDs.remove(id)
            Self.logger.info("Removed shortcut listener and reset shortcut for deleted account: \(id.uuidString, privacy: .public)")
        }

        // 2. Add or update workers
        for account in accounts {
            if workers[account.id] != nil {
                let effective = effectiveFrequency(for: account)
                let wasFlagged = lastReauthFlags[account.id] ?? false
                lastReauthFlags[account.id] = account.needsReauthentication

                if !wasFlagged && account.needsReauthentication {
                    // Without this the only sign of a halted account is a banner inside Settings.
                    Task { await notificationService.sendReauthenticationNeededNotification(account: account) }
                }

                if resolvedFrequencies[account.id] != effective {
                    Self.logger.info("Scheduling restart for account with changed effective frequency: \(account.id.uuidString, privacy: .public)")
                    scheduleRestart(forAccountID: account.id, onlyIfStopped: false)
                } else if wasFlagged && !account.needsReauthentication {
                    // A halted worker never restarts on its own, so resume it once credentials are fixed.
                    Self.logger.info("Account re-authenticated; resuming worker if halted: \(account.id.uuidString, privacy: .public)")
                    scheduleRestart(forAccountID: account.id, onlyIfStopped: true)
                }
            } else {
                Self.logger.info("Creating worker for added account: \(account.id.uuidString, privacy: .public)")
                let worker = createWorker(for: account)
                workers[account.id] = worker
                resolvedFrequencies[account.id] = effectiveFrequency(for: account)
                lastReauthFlags[account.id] = account.needsReauthentication
                Task {
                    await worker.start()
                }
            }

            // Register per-account shortcut listener if not yet registered
            if !registeredShortcutAccountIDs.contains(account.id) {
                let accountID = account.id
                KeyboardShortcuts.onKeyUp(for: .checkMail(accountID: accountID)) { [weak self] in
                    Task { @MainActor [weak self] in
                        await self?.checkMail(accountID: accountID)
                    }
                }
                registeredShortcutAccountIDs.insert(accountID)
                Self.logger.info("Registered shortcut listener for account: \(accountID.uuidString, privacy: .public)")
            }
        }
    }

    /// Replaces an account's worker with a fresh one built from the latest account state.
    ///
    /// - Parameter onlyIfStopped: When `true`, the restart is skipped if the current worker is still running
    ///   (for example because it already recovered by itself).
    private func scheduleRestart(forAccountID id: UUID, onlyIfStopped: Bool) {
        let previousRestart = restartTasks[id]
        restartTasks[id] = Task { [weak self] in
            previousRestart?.cancel()
            _ = await previousRestart?.result
            guard let self = self, self.isRunning else { return }
            guard let currentWorker = self.workers[id] else { return }
            if onlyIfStopped, await currentWorker.active { return }

            await currentWorker.stop()
            guard !Task.isCancelled, self.isRunning else { return }

            // Read the account only after the (possibly slow) stop so a change made meanwhile is not lost.
            guard let latestAccount = self.accountManager.accounts.first(where: { $0.id == id }) else { return }
            let newWorker = self.createWorker(for: latestAccount)
            self.workers[id] = newWorker
            self.resolvedFrequencies[id] = self.effectiveFrequency(for: latestAccount)
            self.lastReauthFlags[id] = latestAccount.needsReauthentication
            await newWorker.start()
            self.restartTasks.removeValue(forKey: id)
        }
    }

    private func createWorker(for account: Account) -> AccountSyncWorker {
        let worker = workerFactory(account) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleNewMailEvent(event)
            }
        }
        observeHealth(of: worker, accountID: account.id)
        return worker
    }

    /// Mirrors a worker's health snapshots into `accountHealth`, replacing any earlier observation for the account.
    ///
    /// Cancelling the previous task also cuts off a replaced worker's late updates. Only the stream is captured,
    /// so the task does not keep the worker alive.
    private func observeHealth(of worker: AccountSyncWorker, accountID: UUID) {
        healthTasks[accountID]?.cancel()
        let updates = worker.healthUpdates
        healthTasks[accountID] = Task { @MainActor [weak self] in
            for await update in updates {
                guard !Task.isCancelled, let self else { return }
                self.receiveHealth(update, accountID: accountID)
            }
        }
    }

    private func receiveHealth(_ update: AccountHealth, accountID: UUID) {
        var merged = update
        // A restart creates a worker whose first snapshot has no history; that must not erase the last check.
        merged.lastSuccessfulCheck = update.lastSuccessfulCheck ?? accountHealth[accountID]?.lastSuccessfulCheck
        accountHealth[accountID] = merged
        evaluateConnectionProblemNotification(for: accountID, health: merged)
    }

    private func setNetworkAvailable(_ isAvailable: Bool) {
        if isAvailable && !isNetworkAvailable {
            lastNetworkRestoredAt = now()
        }
        isNetworkAvailable = isAvailable
    }

    /// Notifies once per outage when an account has failed for long enough that the user must be told.
    ///
    /// This is the only signal when the menu bar icon is hidden. It stays quiet while the network is down and for a
    /// grace period after it returns, because workers that failed through the outage have not reconnected yet.
    private func evaluateConnectionProblemNotification(for accountID: UUID, health: AccountHealth) {
        guard health.consecutiveFailures > 0 else {
            connectionProblemNotified.remove(accountID)
            return
        }
        guard health.consecutiveFailures >= AccountHealth.notificationThreshold,
              !connectionProblemNotified.contains(accountID),
              isNetworkAvailable,
              !isInNetworkRestoredGracePeriod,
              let account = accountManager.accounts.first(where: { $0.id == accountID }),
              !account.needsReauthentication else { return }

        connectionProblemNotified.insert(accountID)
        Self.logger.warning("Account \(accountID.uuidString, privacy: .public) has been unreachable for \(health.consecutiveFailures, privacy: .public) attempts; notifying")
        onConnectionProblemNotification?(account)
        Task { await notificationService.sendConnectionProblemNotification(account: account) }
    }

    private var isInNetworkRestoredGracePeriod: Bool {
        guard let restored = lastNetworkRestoredAt else { return false }
        return now().timeIntervalSince(restored) < Self.networkRestoredGracePeriod
    }

    private func handleNewMailEvent(_ event: NewMailEvent) {
        Self.logger.info("New mail event received from account \(event.accountID.uuidString, privacy: .public): \(event.messages.count, privacy: .public) message(s)")
        onNewMailDetected?(event)
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }
}
