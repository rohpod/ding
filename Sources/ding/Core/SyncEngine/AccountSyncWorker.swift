import Foundation
import os

/// Actor-isolated background worker managing synchronization and new mail detection for a single account.
///
/// ## Concurrency & Actor Isolation Boundary
/// Each configured mail account is assigned its own independent `AccountSyncWorker`.
/// Under Swift 6 strict concurrency, isolation within an `actor` ensures that:
/// - Mutable connection handles (`IMAPConnecting`), active stream continuations, and backoff state machines
///   are protected against concurrent data races.
/// - Multiple accounts can connect, IDLE, and poll concurrently without contention.
/// - Tasks can be cancelled cleanly when accounts are modified or deleted.
///
/// ## Synchronization Modes
/// 1. **Push Mode (`IDLE`)**:
///    Used when the effective frequency is `.always` and the server advertises `IDLE` capability.
///    Maintains a persistent TLS connection, issues `SELECT INBOX`, syncs initial baseline UIDs,
///    and enters `startIdle()`.
///    Upon receiving untagged mailbox notifications (`.newMailAvailable`), it cleanly issues `DONE` (`stopIdle()`),
///    fetches new messages since `lastSeenUID`, updates `SyncState`, emits a `NewMailEvent`, and resumes `IDLE`.
///    To adhere to RFC 2177, the IDLE command is proactively refreshed every 10 minutes, well inside the
///    29-minute server inactivity limit. Each refresh also proves the socket is alive, because a server that
///    never acknowledges `DONE` makes the worker reconnect.
///    Before every (re)entry into IDLE the worker fetches anything already waiting, since servers only announce
///    mail that arrives *during* IDLE.
///
/// 2. **Polling Mode**:
///    Used when the effective frequency is periodic (`.oneMinute`, `.fiveMinutes`, etc.) OR when `.always`
///    is requested but the mail server lacks `IDLE` support (falling back to a 1-minute poll with explicit logs).
///    Connects on a timer loop, fetches any messages arriving since `lastSeenUID`, updates `SyncState`,
///    emits `NewMailEvent`, and immediately disconnects to preserve system RAM and battery life.
///
/// ## Failure Resilience & Backoff
/// Transient failures trigger exponential backoff starting at 5 seconds and doubling up to 300 seconds (5 minutes),
/// with up to 20% random jitter. Backoff resets only after a *complete* connect-and-fetch cycle succeeds, so a failure
/// late in the cycle keeps backing off instead of reconnecting every few seconds.
///
/// An explicit credential rejection (`.authenticationFailed`) halts the sync loop immediately to prevent account
/// lockout and sets `needsReauthentication = true`. A bare `NO`/`BAD` at login (`.loginRejected`) is ambiguous, so it
/// halts only after several consecutive rejections, while temporary refusals (`.temporarilyUnavailable`) are retried
/// indefinitely. A successful login clears a stale flag.
///
/// `reconnectNow()` lets the engine force a fresh connection after the Mac wakes or the network returns.
public actor AccountSyncWorker {
    private static let logger = Logger(subsystem: DingLog.subsystem, category: "AccountSyncWorker")

    /// The account managed by this worker.
    public let account: Account

    private let imapClient: any IMAPConnecting
    private let manualCheckClientFactory: @Sendable () -> any IMAPConnecting
    private let syncStateStore: any SyncStateStoreProtocol
    private let passwordProvider: @Sendable (UUID) async throws -> String
    private let reauthenticationHandler: (@Sendable (UUID) async -> Void)?
    private let authenticationRecoveredHandler: (@Sendable (UUID) async -> Void)?
    private let sleepProvider: @Sendable (Duration) async throws -> Void
    private let onNewMail: (@Sendable (NewMailEvent) -> Void)?
    private let defaultSyncFrequency: SyncFrequency
    private let idleRefreshDuration: Duration
    private let backoffJitter: @Sendable () -> Double

    private let wakeSignal = WakeSignal()

    private var syncTask: Task<Void, Never>?
    private var isRunning: Bool = false
    private var isFetchingNewMail: Bool = false
    private var currentRetryCount: Int = 0
    private var consecutiveLoginRejections: Int = 0
    private var hasClearedReauthenticationFlag: Bool = false

    /// Number of back-to-back ambiguous login rejections (a bare `NO`/`BAD`) tolerated before the account is
    /// flagged as needing a new password.
    private static let maxConsecutiveLoginRejections = 3
    private var hasLoadedBaseline: Bool = false
    private var lastSeenUID: UInt32 = 0
    private var currentUIDValidity: UInt32 = 0

    /// Indicates whether the worker is currently running its sync loop.
    public var active: Bool {
        isRunning
    }

    /// Queries the current absolute unread message count for this account's inbox.
    ///
    /// Always uses a short-lived, dedicated connection so a manual check can never interrupt the
    /// sync loop's IDLE session or race with its connect/disconnect cycle. Leaves baseline UID state untouched.
    ///
    /// - Returns: The total unread email count in INBOX.
    /// - Throws: An error if connection, authentication, or query fails.
    public func checkUnreadCount() async throws -> Int {
        let client = manualCheckClientFactory()
        do {
            let password = try await passwordProvider(account.id)
            try await client.connect(host: account.provider.imapHost, port: account.provider.imapPort)
            try await client.login(email: account.email, password: password)
            let count = try await client.fetchUnreadCount()
            await client.disconnect()
            return count
        } catch {
            await client.disconnect()
            throw error
        }
    }

    /// Initializes a new per-account sync worker.
    ///
    /// - Parameters:
    ///   - account: The mail account to watch.
    ///   - imapClient: The network client conforming to `IMAPConnecting`. Defaults to a new `NIOIMAPClient()`.
    ///   - manualCheckClientFactory: Produces the dedicated client used for manual unread checks. Defaults to `NIOIMAPClient()`.
    ///   - syncStateStore: Disk store for UID tracking. Defaults to `SyncStateStore.shared`.
    ///   - defaultSyncFrequency: Global fallback frequency. Defaults to `AppPreferences.shared.defaultSyncFrequency`.
    ///   - idleRefreshDuration: Inactivity duration before re-issuing IDLE. Defaults to 28 minutes.
    ///   - passwordProvider: Async closure retrieving the decrypted password from Keychain.
    ///   - reauthenticationHandler: Closure invoked when authentication fails.
    ///   - authenticationRecoveredHandler: Closure invoked when a previously flagged account logs in successfully.
    ///   - sleepProvider: Timing closure for async delays (injected in unit tests).
    ///   - backoffJitter: Returns a fraction in `0...1` added on top of each backoff delay. Defaults to random 0-20%.
    ///   - onNewMail: Callback invoked when new messages are detected.
    public init(
        account: Account,
        imapClient: (any IMAPConnecting)? = nil,
        manualCheckClientFactory: (@Sendable () -> any IMAPConnecting)? = nil,
        syncStateStore: (any SyncStateStoreProtocol)? = nil,
        defaultSyncFrequency: SyncFrequency = .always,
        idleRefreshDuration: Duration = .seconds(600), // 10 minutes
        passwordProvider: (@Sendable (UUID) async throws -> String)? = nil,
        reauthenticationHandler: (@Sendable (UUID) async -> Void)? = nil,
        authenticationRecoveredHandler: (@Sendable (UUID) async -> Void)? = nil,
        sleepProvider: (@Sendable (Duration) async throws -> Void)? = nil,
        backoffJitter: (@Sendable () -> Double)? = nil,
        onNewMail: (@Sendable (NewMailEvent) -> Void)? = nil
    ) {
        self.account = account
        self.imapClient = imapClient ?? NIOIMAPClient()
        self.manualCheckClientFactory = manualCheckClientFactory ?? { NIOIMAPClient() }
        self.syncStateStore = syncStateStore ?? SyncStateStore.shared
        self.defaultSyncFrequency = defaultSyncFrequency
        self.idleRefreshDuration = idleRefreshDuration

        self.passwordProvider = passwordProvider ?? { accountID in
            try await MainActor.run {
                try AccountManager.shared.password(forAccountID: accountID)
            }
        }

        self.reauthenticationHandler = reauthenticationHandler ?? { accountID in
            await MainActor.run {
                try? AccountManager.shared.setNeedsReauthentication(forAccountID: accountID, needsReauthentication: true)
            }
        }

        self.authenticationRecoveredHandler = authenticationRecoveredHandler ?? { accountID in
            await MainActor.run {
                let manager = AccountManager.shared
                guard manager.accounts.first(where: { $0.id == accountID })?.needsReauthentication == true else { return }
                try? manager.setNeedsReauthentication(forAccountID: accountID, needsReauthentication: false)
            }
        }

        self.sleepProvider = sleepProvider ?? { duration in
            try await Task.sleep(for: duration)
        }

        self.backoffJitter = backoffJitter ?? { Double.random(in: 0...0.2) }
        self.onNewMail = onNewMail
    }

    deinit {
        syncTask?.cancel()
    }

    /// Starts the background synchronization loop for this account.
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        Self.logger.info("Starting sync worker for account \(self.account.id.uuidString, privacy: .public)")

        syncTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    /// Drops the current connection and retries immediately.
    ///
    /// Called after the Mac wakes from sleep or the network returns: an IDLE socket can be dead while still
    /// looking connected, and would otherwise only be noticed at the next refresh.
    public func reconnectNow() async {
        guard isRunning else { return }
        Self.logger.info("Reconnect requested for account \(self.account.id.uuidString, privacy: .public)")
        currentRetryCount = 0
        wakeSignal.signal()
        await imapClient.disconnect()
    }

    /// Cleanly cancels the sync loop and disconnects active network sessions.
    public func stop() async {
        guard isRunning else { return }
        isRunning = false
        Self.logger.info("Stopping sync worker for account \(self.account.id.uuidString, privacy: .public)")

        syncTask?.cancel()
        syncTask = nil
        wakeSignal.signal()
        await imapClient.disconnect()
    }

    // MARK: - Main Loop Orchestration

    private func runLoop() async {
        while isRunning && !Task.isCancelled {
            do {
                let effectiveFrequency = resolveEffectiveFrequency()
                let password = try await passwordProvider(account.id)

                Self.logger.debug("Connecting to \(self.account.provider.imapHost, privacy: .public):\(self.account.provider.imapPort, privacy: .public)")
                try await imapClient.connect(host: account.provider.imapHost, port: account.provider.imapPort)

                try await imapClient.login(email: account.email, password: password)
                consecutiveLoginRejections = 0
                await clearReauthenticationFlagIfNeeded()
                let mailboxStatus = try await imapClient.selectInbox()

                // Baseline sync check
                try processInitialBaseline(mailboxStatus: mailboxStatus)

                let canUseIdle: Bool
                if effectiveFrequency == .always {
                    canUseIdle = try await imapClient.supportsIdle()
                } else {
                    canUseIdle = false
                }

                if canUseIdle {
                    Self.logger.info("Mode: IDLE push selected for account \(self.account.id.uuidString, privacy: .public)")
                    try await runIdleMode()
                } else {
                    if effectiveFrequency == .always {
                        Self.logger.info("Mode: Fallback 1-minute polling selected (server lacks IDLE) for account \(self.account.id.uuidString, privacy: .public)")
                    } else {
                        Self.logger.info("Mode: Periodic polling selected (\(effectiveFrequency.displayName, privacy: .public)) for account \(self.account.id.uuidString, privacy: .public)")
                    }
                    try await runPollMode(frequency: effectiveFrequency)
                }
            } catch let error as IMAPClientError where error == .authenticationFailed {
                Self.logger.fault("Authentication failed for account \(self.account.id.uuidString, privacy: .public). Halting worker and flagging reauthentication requirement.")
                await haltForReauthentication()
                break
            } catch let error as KeychainError where error == .accessDeniedOrCancelled || error == .itemNotFound {
                Self.logger.fault("Keychain access denied, cancelled, or item missing for account \(self.account.id.uuidString, privacy: .public). Halting worker and flagging reauthentication requirement.")
                await haltForReauthentication()
                break
            } catch is CancellationError {
                Self.logger.debug("Sync worker loop cancelled for account \(self.account.id.uuidString, privacy: .public)")
                break
            } catch {
                await imapClient.disconnect()
                guard isRunning && !Task.isCancelled else { break }

                if let imapError = error as? IMAPClientError, case .loginRejected = imapError {
                    consecutiveLoginRejections += 1
                    if consecutiveLoginRejections >= Self.maxConsecutiveLoginRejections {
                        Self.logger.fault("Login rejected \(self.consecutiveLoginRejections) times in a row for account \(self.account.id.uuidString, privacy: .public). Halting worker and flagging reauthentication requirement.")
                        await haltForReauthentication()
                        break
                    }
                } else {
                    consecutiveLoginRejections = 0
                }

                let backoffDelay = computeBackoffDelay()
                Self.logger.warning("Sync error for account \(self.account.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public). Retrying in \(Int(backoffDelay.components.seconds))s (attempt #\(self.currentRetryCount))")
                currentRetryCount += 1

                do {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            do {
                                try await self.sleepProvider(backoffDelay)
                            } catch is CancellationError {}
                        }
                        group.addTask {
                            await self.wakeSignal.wait()
                        }
                        try await group.next()
                        group.cancelAll()
                    }
                } catch {
                    break // Task cancelled while sleeping
                }
            }
        }

        Self.logger.info("Sync worker loop terminated for account \(self.account.id.uuidString, privacy: .public)")
    }

    // MARK: - IDLE Mode

    private func runIdleMode() async throws {
        while isRunning && !Task.isCancelled {
            // Catch up on anything that arrived while disconnected or between IDLE sessions: servers only
            // announce mail that arrives during IDLE, so this must run before every (re)entry.
            try await fetchAndEmitNewMail()
            currentRetryCount = 0 // A full connect + fetch cycle succeeded: reset backoff

            let stream = try await imapClient.startIdle()

            // Run IDLE stream with a refresh timer and wake signal
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for try await event in stream {
                        if Task.isCancelled { break }
                        switch event {
                        case .newMailAvailable:
                            Self.logger.info("IDLE notification received: new mail available")
                            // RFC 2177: stop IDLE before issuing UID FETCH
                            try await self.imapClient.stopIdle()
                            try await self.fetchAndEmitNewMail()
                            return // Exit task to restart IDLE loop with fresh state
                        }
                    }
                }

                group.addTask {
                    do {
                        try await self.sleepProvider(self.idleRefreshDuration)
                        Self.logger.debug("IDLE refresh threshold reached (\(self.idleRefreshDuration.components.seconds)s); re-issuing IDLE")
                        try await self.imapClient.stopIdle()
                    } catch is CancellationError {}
                }

                group.addTask {
                    // Woken by `stop()` or `reconnectNow()`. Ending this child ends the IDLE session; the caller
                    // then either exits (stopped) or reconnects (the connection was dropped).
                    await self.wakeSignal.wait()
                }

                // Wait for either new mail, refresh timeout, or manual wake signal
                try await group.next()
                group.cancelAll()
            }
        }
    }

    // MARK: - Poll Mode

    private func runPollMode(frequency: SyncFrequency) async throws {
        let interval: Duration
        if frequency == .always {
            // Fallback for .always when IDLE is unsupported
            interval = .seconds(60)
        } else if let seconds = frequency.intervalSeconds {
            interval = .seconds(Int64(seconds))
        } else {
            interval = .seconds(60)
        }

        // 1. Fetch any new messages immediately
        try await fetchAndEmitNewMail()
        currentRetryCount = 0 // A full connect + fetch cycle succeeded: reset backoff

        // 2. Disconnect to preserve RAM and power in polling mode
        await imapClient.disconnect()

        // 3. Sleep until the next polling cycle or wake signal
        Self.logger.debug("Poll completed; sleeping for \(interval.components.seconds)s")
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                do {
                    try await self.sleepProvider(interval)
                } catch is CancellationError {}
            }

            group.addTask {
                await self.wakeSignal.wait()
            }

            try await group.next()
            group.cancelAll()
        }
    }

    // MARK: - Message Fetching & State Persistence

    private func processInitialBaseline(mailboxStatus: MailboxStatus) throws {
        if hasLoadedBaseline {
            // State is already held in memory: avoid redundant disk read and JSON decode on every poll cycle.
            if self.currentUIDValidity != mailboxStatus.uidValidity {
                // UIDVALIDITY mismatch: server renumbered mailbox. Reset baseline to avoid spamming old history.
                let baselineUID = mailboxStatus.uidNext > 1 ? mailboxStatus.uidNext - 1 : 0
                Self.logger.warning("UIDVALIDITY changed (\(self.currentUIDValidity) -> \(mailboxStatus.uidValidity)). Resetting baseline UID to \(baselineUID).")

                let newState = SyncState(
                    accountID: account.id,
                    uidValidity: mailboxStatus.uidValidity,
                    lastSeenUID: baselineUID,
                    lastSyncedAt: Date()
                )
                try syncStateStore.updateState(newState)
                self.lastSeenUID = baselineUID
                self.currentUIDValidity = mailboxStatus.uidValidity
            }
            return
        }

        let existing = try syncStateStore.state(forAccountID: account.id)

        if let state = existing {
            if state.uidValidity != mailboxStatus.uidValidity {
                // UIDVALIDITY mismatch: server renumbered mailbox. Reset baseline to avoid spamming old history.
                let baselineUID = mailboxStatus.uidNext > 1 ? mailboxStatus.uidNext - 1 : 0
                Self.logger.warning("UIDVALIDITY changed (\(state.uidValidity) -> \(mailboxStatus.uidValidity)). Resetting baseline UID to \(baselineUID).")

                let newState = SyncState(
                    accountID: account.id,
                    uidValidity: mailboxStatus.uidValidity,
                    lastSeenUID: baselineUID,
                    lastSyncedAt: Date()
                )
                try syncStateStore.updateState(newState)
                self.lastSeenUID = baselineUID
                self.currentUIDValidity = mailboxStatus.uidValidity
            } else {
                self.lastSeenUID = state.lastSeenUID
                self.currentUIDValidity = state.uidValidity
            }
        } else {
            // First time tracking this account: establish baseline at uidNext - 1
            let baselineUID = mailboxStatus.uidNext > 1 ? mailboxStatus.uidNext - 1 : 0
            Self.logger.info("Establishing initial baseline UID \(baselineUID) for account \(self.account.id.uuidString, privacy: .public)")

            let newState = SyncState(
                accountID: account.id,
                uidValidity: mailboxStatus.uidValidity,
                lastSeenUID: baselineUID,
                lastSyncedAt: Date()
            )
            try syncStateStore.updateState(newState)
            self.lastSeenUID = baselineUID
            self.currentUIDValidity = mailboxStatus.uidValidity
        }
        self.hasLoadedBaseline = true
    }

    private func fetchAndEmitNewMail() async throws {
        guard !isFetchingNewMail else {
            Self.logger.debug("fetchAndEmitNewMail already in progress for account \(self.account.id.uuidString, privacy: .public); skipping concurrent call.")
            return
        }
        isFetchingNewMail = true
        defer { isFetchingNewMail = false }

        Self.logger.debug("Checking for new messages arriving after UID \(self.lastSeenUID, privacy: .public)")
        let messages = try await imapClient.fetchNewMessages(sinceUID: self.lastSeenUID)

        guard !messages.isEmpty else {
            Self.logger.debug("No new messages found")
            return
        }

        let newLastSeenUID = max(messages.map(\.uid).max() ?? self.lastSeenUID, self.lastSeenUID)

        let updatedState = SyncState(
            accountID: account.id,
            uidValidity: self.currentUIDValidity,
            lastSeenUID: newLastSeenUID,
            lastSyncedAt: Date()
        )
        do {
            try syncStateStore.updateState(updatedState)
        } catch {
            // Persistence failed (for example a full disk). Notify anyway so the user is not left without an alert;
            // the in-memory marker still advances so a transient save failure cannot cause repeated alerts.
            Self.logger.error("Failed to persist sync state for account \(self.account.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        self.lastSeenUID = newLastSeenUID

        Self.logger.info("Detected \(messages.count, privacy: .public) new message(s) for account \(self.account.id.uuidString, privacy: .public). Highest UID is now \(self.lastSeenUID, privacy: .public).")
        let event = NewMailEvent(accountID: account.id, messages: messages)
        onNewMail?(event)
    }

    // MARK: - Helpers

    /// Stops the loop and flags the account so the user is asked for a new app password.
    private func haltForReauthentication() async {
        isRunning = false
        await reauthenticationHandler?(account.id)
        await imapClient.disconnect()
    }

    /// Clears a stale `needsReauthentication` flag once the server accepts the stored credentials again.
    private func clearReauthenticationFlagIfNeeded() async {
        guard account.needsReauthentication, !hasClearedReauthenticationFlag else { return }
        hasClearedReauthenticationFlag = true
        Self.logger.info("Login succeeded for previously flagged account \(self.account.id.uuidString, privacy: .public); clearing re-authentication flag")
        await authenticationRecoveredHandler?(account.id)
    }

    private func resolveEffectiveFrequency() -> SyncFrequency {
        if account.syncFrequency == .useDefault {
            return defaultSyncFrequency
        }
        return account.syncFrequency
    }

    private func computeBackoffDelay() -> Duration {
        let baseSeconds: Double = 5.0
        let maxSeconds: Double = 300.0
        let multiplier = pow(2.0, Double(min(currentRetryCount, 6)))
        let delay = min(baseSeconds * multiplier, maxSeconds)
        let jittered = delay * (1 + max(0, backoffJitter()))
        return .seconds(Int64(jittered))
    }
}

// MARK: - Wake Signal Coordination

/// Thread-safe coordination signal used to interrupt an active sleep or IDLE session on demand.
///
/// `@unchecked Sendable` justification: all mutable state (`continuations`) is only accessed while holding `lock`.
final class WakeSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: CheckedContinuation<Void, Never>] = [:]

    func wait() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if Task.isCancelled {
                    // The cancellation handler already ran before this continuation existed; without this
                    // check the continuation would be registered after the only wake-up chance has passed.
                    lock.unlock()
                    continuation.resume()
                    return
                }
                continuations[id] = continuation
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            let cont = continuations.removeValue(forKey: id)
            lock.unlock()
            cont?.resume()
        }
    }

    func signal() {
        lock.lock()
        let all = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for cont in all {
            cont.resume()
        }
    }
}
