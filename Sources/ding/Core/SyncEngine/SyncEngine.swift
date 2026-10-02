import Combine
import Foundation
import KeyboardShortcuts
import os

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
/// Types of notifications generated as a result of manual mail checking.
public enum ManualCheckNotification: Equatable, Sendable {
    /// Zero unread emails detected across checked accounts.
    case zeroUnread

    /// Positive unread email count detected for a specific account.
    case accountUnread(account: Account, count: Int)
}

@MainActor
public final class SyncEngine: ObservableObject {
    nonisolated private static let logger = Logger(subsystem: DingLog.subsystem, category: "SyncEngine")

    /// The shared singleton instance of `SyncEngine`.
    public static let shared = SyncEngine()

    /// Factory type responsible for constructing `AccountSyncWorker` instances (injectable for unit testing).
    public typealias WorkerFactory = @Sendable (Account, @escaping @Sendable (NewMailEvent) -> Void) -> AccountSyncWorker

    /// Callback invoked whenever any managed account worker detects new mail.
    public var onNewMailDetected: ((NewMailEvent) -> Void)?

    /// Callback invoked whenever a manual mail check produces a notification (injectable for unit testing).
    public var onManualCheckNotification: ((ManualCheckNotification) -> Void)?

    /// Currently active workers keyed by `Account.id`.
    public private(set) var workers: [UUID: AccountSyncWorker] = [:]

    /// Indicates whether the sync engine is active.
    @Published public private(set) var isRunning: Bool = false

    /// The list of configured accounts that have manual checking enabled.
    public var manualCheckAccounts: [Account] {
        accountManager.accounts.filter { $0.includeInManualCheck }
    }

    private let accountManager: AccountManager
    private let appPreferences: AppPreferences
    private let notificationService: NotificationService
    private let workerFactory: WorkerFactory
    private var cancellables = Set<AnyCancellable>()
    private var accountObservation: AnyCancellable?
    private var eventContinuations: [UUID: AsyncStream<NewMailEvent>.Continuation] = [:]
    private var registeredShortcutAccountIDs = Set<UUID>()

    /// Initializes a new sync engine coordinator.
    ///
    /// - Parameters:
    ///   - accountManager: Account store manager to observe. Defaults to `AccountManager.shared`.
    ///   - appPreferences: Global preferences store. Defaults to `AppPreferences.shared`.
    ///   - notificationService: Notification delivery service. Defaults to `NotificationService.shared`.
    ///   - workerFactory: Factory closure for generating account workers (injected in unit tests).
    public init(
        accountManager: AccountManager = .shared,
        appPreferences: AppPreferences = .shared,
        notificationService: NotificationService = .shared,
        workerFactory: WorkerFactory? = nil
    ) {
        self.accountManager = accountManager
        self.appPreferences = appPreferences
        self.notificationService = notificationService
        let defaultFrequency = appPreferences.defaultSyncFrequency

        self.workerFactory = workerFactory ?? { account, onNewMail in
            AccountSyncWorker(
                account: account,
                defaultSyncFrequency: defaultFrequency,
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
    }

    /// Stops all account sync workers and cancels subscriptions.
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        Self.logger.info("Stopping SyncEngine and all child workers")

        cancellables.removeAll()

        KeyboardShortcuts.disable(.checkAllMail)
        for id in registeredShortcutAccountIDs {
            KeyboardShortcuts.disable(.checkMail(accountID: id))
        }
        registeredShortcutAccountIDs.removeAll()

        for (id, worker) in workers {
            Task {
                await worker.stop()
            }
            Self.logger.debug("Tore down worker for account: \(id.uuidString, privacy: .public)")
        }
        workers.removeAll()

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
            Self.logger.error("Failed to check unread count for account \(accountID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
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

        await withTaskGroup(of: (Account, Int)?.self) { group in
            for account in eligibleAccounts {
                if let worker = self.workers[account.id] {
                    group.addTask {
                        do {
                            let count = try await worker.checkUnreadCount()
                            return (account, count)
                        } catch {
                            Self.logger.error("Failed to check unread count for account \(account.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
                            return nil
                        }
                    }
                }
            }

            for await result in group {
                if let result = result {
                    results.append(result)
                }
            }
        }

        guard !results.isEmpty else {
            Self.logger.warning("All manual check queries failed or yielded no results; skipping notifications")
            return
        }

        let totalUnread = results.reduce(0) { $0 + $1.unreadCount }

        if totalUnread == 0 {
            await deliverZeroUnreadNotification()
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

    private func deliverAccountUnreadNotification(account: Account, count: Int) async {
        Self.logger.info("Delivering unread notification for \(account.displayName, privacy: .public): \(count, privacy: .public)")
        onManualCheckNotification?(.accountUnread(account: account, count: count))
        await notificationService.sendAccountUnreadNotification(account: account, unreadCount: count)
    }

    // MARK: - Account Worker Synchronization

    private func syncWorkers(with accounts: [Account]) {
        guard isRunning else { return }
        let currentIDs = Set(accounts.map(\.id))
        let existingIDs = Set(workers.keys)

        // 1. Remove workers for deleted accounts
        let removedIDs = existingIDs.subtracting(currentIDs)
        for id in removedIDs {
            if let worker = workers.removeValue(forKey: id) {
                Self.logger.info("Removing worker for deleted account: \(id.uuidString, privacy: .public)")
                Task {
                    await worker.stop()
                }
            }
        }

        let removedShortcutIDs = registeredShortcutAccountIDs.subtracting(currentIDs)
        for id in removedShortcutIDs {
            KeyboardShortcuts.disable(.checkMail(accountID: id))
            KeyboardShortcuts.reset(.checkMail(accountID: id))
            registeredShortcutAccountIDs.remove(id)
            Self.logger.info("Removed shortcut listener and reset shortcut for deleted account: \(id.uuidString, privacy: .public)")
        }

        // 2. Add or update workers
        for account in accounts {
            if let existingWorker = workers[account.id] {
                // If frequency changed, restart worker with updated settings
                Task {
                    let workerAccount = existingWorker.account
                    if workerAccount.syncFrequency != account.syncFrequency {
                        Self.logger.info("Restarting worker for account with changed frequency: \(account.id.uuidString, privacy: .public)")
                        await existingWorker.stop()
                        let newWorker = self.createWorker(for: account)
                        self.workers[account.id] = newWorker
                        await newWorker.start()
                    }
                }
            } else {
                Self.logger.info("Creating worker for added account: \(account.id.uuidString, privacy: .public)")
                let worker = createWorker(for: account)
                workers[account.id] = worker
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

    private func createWorker(for account: Account) -> AccountSyncWorker {
        workerFactory(account) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleNewMailEvent(event)
            }
        }
    }

    private func handleNewMailEvent(_ event: NewMailEvent) {
        Self.logger.info("New mail event received from account \(event.accountID.uuidString, privacy: .public): \(event.messages.count, privacy: .public) message(s)")
        onNewMailDetected?(event)
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }
}
