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
///    To adhere to RFC 2177, the IDLE command is proactively refreshed every 28 minutes before the 29-minute
///    server inactivity timeout.
///
/// 2. **Polling Mode**:
///    Used when the effective frequency is periodic (`.oneMinute`, `.fiveMinutes`, etc.) OR when `.always`
///    is requested but the mail server lacks `IDLE` support (falling back to a 1-minute poll with explicit logs).
///    Connects on a timer loop, fetches any messages arriving since `lastSeenUID`, updates `SyncState`,
///    emits `NewMailEvent`, and immediately disconnects to preserve system RAM and battery life.
///
/// ## Failure Resilience & Backoff
/// Transient network errors (`.connectionFailed`, `.timeout`, `.tlsHandshakeFailed`) trigger exponential backoff
/// starting at 5 seconds and doubling up to 300 seconds (5 minutes). Backoff resets upon the next successful sync pass.
///
/// Critical credential rejection (`.authenticationFailed`) halts the sync loop immediately to prevent account lockout,
/// sets `needsReauthentication = true` on `AccountManager`, and logs a high-priority diagnostic.
public actor AccountSyncWorker {
    private static let logger = Logger(subsystem: "com.ding.mac", category: "AccountSyncWorker")

    /// The account managed by this worker.
    public let account: Account

    private let imapClient: any IMAPConnecting
    private let syncStateStore: any SyncStateStoreProtocol
    private let passwordProvider: @Sendable (UUID) async throws -> String
    private let reauthenticationHandler: (@Sendable (UUID) async -> Void)?
    private let sleepProvider: @Sendable (Duration) async throws -> Void
    private let onNewMail: (@Sendable (NewMailEvent) -> Void)?
    private let defaultSyncFrequency: SyncFrequency
    private let idleRefreshDuration: Duration

    private var syncTask: Task<Void, Never>?
    private var isRunning: Bool = false
    private var currentRetryCount: Int = 0
    private var lastSeenUID: UInt32 = 0
    private var currentUIDValidity: UInt32 = 0

    /// Indicates whether the worker is currently running its sync loop.
    public var active: Bool {
        isRunning
    }

    /// Initializes a new per-account sync worker.
    ///
    /// - Parameters:
    ///   - account: The mail account to watch.
    ///   - imapClient: The network client conforming to `IMAPConnecting`. Defaults to a new `NIOIMAPClient()`.
    ///   - syncStateStore: Disk store for UID tracking. Defaults to `SyncStateStore()`.
    ///   - defaultSyncFrequency: Global fallback frequency. Defaults to `AppPreferences.shared.defaultSyncFrequency`.
    ///   - idleRefreshDuration: Inactivity duration before re-issuing IDLE. Defaults to 28 minutes.
    ///   - passwordProvider: Async closure retrieving the decrypted password from Keychain.
    ///   - reauthenticationHandler: Closure invoked when authentication fails.
    ///   - sleepProvider: Timing closure for async delays (injected in unit tests).
    ///   - onNewMail: Callback invoked when new messages are detected.
    public init(
        account: Account,
        imapClient: (any IMAPConnecting)? = nil,
        syncStateStore: (any SyncStateStoreProtocol)? = nil,
        defaultSyncFrequency: SyncFrequency = .always,
        idleRefreshDuration: Duration = .seconds(1680), // 28 minutes
        passwordProvider: (@Sendable (UUID) async throws -> String)? = nil,
        reauthenticationHandler: (@Sendable (UUID) async -> Void)? = nil,
        sleepProvider: (@Sendable (Duration) async throws -> Void)? = nil,
        onNewMail: (@Sendable (NewMailEvent) -> Void)? = nil
    ) {
        self.account = account
        self.imapClient = imapClient ?? NIOIMAPClient()
        self.syncStateStore = syncStateStore ?? SyncStateStore()
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

        self.sleepProvider = sleepProvider ?? { duration in
            try await Task.sleep(for: duration)
        }

        self.onNewMail = onNewMail
    }

    deinit {
        syncTask?.cancel()
    }

    /// Starts the background synchronization loop for this account.
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        Self.logger.info("Starting sync worker for account \(self.account.id.uuidString, privacy: .public) (\(self.account.displayName, privacy: .public))")

        syncTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    /// Cleanly cancels the sync loop and disconnects active network sessions.
    public func stop() async {
        guard isRunning else { return }
        isRunning = false
        Self.logger.info("Stopping sync worker for account \(self.account.id.uuidString, privacy: .public)")

        syncTask?.cancel()
        syncTask = nil
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
                let mailboxStatus = try await imapClient.selectInbox()

                // Baseline sync check
                try processInitialBaseline(mailboxStatus: mailboxStatus)
                currentRetryCount = 0 // Reset backoff on successful handshake & baseline sync

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
                isRunning = false
                await reauthenticationHandler?(account.id)
                await imapClient.disconnect()
                break
            } catch is CancellationError {
                Self.logger.debug("Sync worker loop cancelled for account \(self.account.id.uuidString, privacy: .public)")
                break
            } catch {
                await imapClient.disconnect()
                guard isRunning && !Task.isCancelled else { break }

                let backoffDelay = computeBackoffDelay()
                Self.logger.warning("Sync error for account \(self.account.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public). Retrying in \(Int(backoffDelay.components.seconds))s (attempt #\(self.currentRetryCount))")
                currentRetryCount += 1

                do {
                    try await sleepProvider(backoffDelay)
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
            let stream = try await imapClient.startIdle()

            // Run IDLE stream with a refresh timer to stay ahead of server timeout
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
                        case .idleTimedOut:
                            try await self.imapClient.stopIdle()
                            return
                        }
                    }
                }

                group.addTask {
                    try await self.sleepProvider(self.idleRefreshDuration)
                    Self.logger.debug("IDLE refresh threshold reached (\(self.idleRefreshDuration.components.seconds)s); re-issuing IDLE")
                    try await self.imapClient.stopIdle()
                }

                // Wait for either new mail or refresh timeout
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

        // 2. Disconnect to preserve RAM and power in polling mode
        await imapClient.disconnect()

        // 3. Sleep until the next polling cycle
        Self.logger.debug("Poll completed; sleeping for \(interval.components.seconds)s")
        try await sleepProvider(interval)
    }

    // MARK: - Message Fetching & State Persistence

    private func processInitialBaseline(mailboxStatus: MailboxStatus) throws {
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
    }

    private func fetchAndEmitNewMail() async throws {
        Self.logger.debug("Checking for new messages arriving after UID \(self.lastSeenUID, privacy: .public)")
        let messages = try await imapClient.fetchNewMessages(sinceUID: self.lastSeenUID)

        guard !messages.isEmpty else {
            Self.logger.debug("No new messages found")
            return
        }

        let maxUID = messages.map(\.uid).max() ?? self.lastSeenUID
        self.lastSeenUID = max(maxUID, self.lastSeenUID)

        let updatedState = SyncState(
            accountID: account.id,
            uidValidity: self.currentUIDValidity,
            lastSeenUID: self.lastSeenUID,
            lastSyncedAt: Date()
        )
        try syncStateStore.updateState(updatedState)

        Self.logger.info("Detected \(messages.count, privacy: .public) new message(s) for account \(self.account.id.uuidString, privacy: .public). Highest UID is now \(self.lastSeenUID, privacy: .public).")
        let event = NewMailEvent(accountID: account.id, messages: messages)
        onNewMail?(event)
    }

    // MARK: - Helpers

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
        return .seconds(Int64(delay))
    }
}
