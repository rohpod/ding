import Combine
import Foundation
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
@MainActor
public final class SyncEngine: ObservableObject {
    private static let logger = Logger(subsystem: "com.ding.mac", category: "SyncEngine")

    /// The shared singleton instance of `SyncEngine`.
    public static let shared = SyncEngine()

    /// Factory type responsible for constructing `AccountSyncWorker` instances (injectable for unit testing).
    public typealias WorkerFactory = @Sendable (Account, @escaping @Sendable (NewMailEvent) -> Void) -> AccountSyncWorker

    /// Callback invoked whenever any managed account worker detects new mail.
    public var onNewMailDetected: ((NewMailEvent) -> Void)?

    /// Currently active workers keyed by `Account.id`.
    public private(set) var workers: [UUID: AccountSyncWorker] = [:]

    /// Indicates whether the sync engine is active.
    @Published public private(set) var isRunning: Bool = false

    private let accountManager: AccountManager
    private let appPreferences: AppPreferences
    private let workerFactory: WorkerFactory
    private var cancellables = Set<AnyCancellable>()
    private var eventContinuations: [UUID: AsyncStream<NewMailEvent>.Continuation] = [:]

    /// Initializes a new sync engine coordinator.
    ///
    /// - Parameters:
    ///   - accountManager: Account store manager to observe. Defaults to `AccountManager.shared`.
    ///   - appPreferences: Global preferences store. Defaults to `AppPreferences.shared`.
    ///   - workerFactory: Factory closure for generating account workers (injected in unit tests).
    public init(
        accountManager: AccountManager = .shared,
        appPreferences: AppPreferences = .shared,
        workerFactory: WorkerFactory? = nil
    ) {
        self.accountManager = accountManager
        self.appPreferences = appPreferences
        let defaultFrequency = appPreferences.defaultSyncFrequency

        self.workerFactory = workerFactory ?? { account, onNewMail in
            AccountSyncWorker(
                account: account,
                defaultSyncFrequency: defaultFrequency,
                onNewMail: onNewMail
            )
        }
    }

    /// Starts the sync engine, spinning up workers for all currently configured accounts and observing changes.
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        Self.logger.info("Starting SyncEngine with \(self.accountManager.accounts.count, privacy: .public) account(s)")

        // Synchronize initial workers
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
