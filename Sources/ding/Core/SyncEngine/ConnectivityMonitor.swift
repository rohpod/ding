import AppKit
import Foundation
import Network
import os

/// Detects the Mac waking from sleep and the network coming back, so sync workers can reconnect promptly.
///
/// ## Why this exists
/// An IMAP IDLE connection that was open before sleep (or before a Wi-Fi change) is usually dead afterwards,
/// yet nothing tells the socket so. Without an explicit trigger the worker only notices at its next scheduled
/// refresh, leaving the user without notifications in the meantime.
///
/// Triggers are debounced because the network typically becomes usable a moment *after* the wake event.
@MainActor
final class ConnectivityMonitor {
    private static let logger = Logger(subsystem: DingLog.subsystem, category: "Connectivity")

    /// Invoked (on the main actor) when workers should drop their connections and reconnect.
    var onReconnectNeeded: (@MainActor () -> Void)?

    private let debounce: Duration
    private let pathMonitor = NWPathMonitor()
    private var wakeObserver: NSObjectProtocol?
    private var lastPathStatus: NWPath.Status?
    private var pendingTrigger: Task<Void, Never>?
    private var isStarted = false

    init(debounce: Duration = .seconds(3)) {
        self.debounce = debounce
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                Self.logger.info("System woke from sleep")
                self?.scheduleTrigger()
            }
        }

        pathMonitor.pathUpdateHandler = { [weak self] path in
            let status = path.status
            Task { @MainActor [weak self] in
                self?.handlePathUpdate(status: status)
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.ding.mac.v3.connectivity", qos: .utility))
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        pendingTrigger?.cancel()
        pendingTrigger = nil
        pathMonitor.cancel()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = nil
    }

    /// Reacts to a network path change; only a transition *into* a usable network is interesting.
    func handlePathUpdate(status: NWPath.Status) {
        let previous = lastPathStatus
        lastPathStatus = status
        guard let previous, previous != .satisfied, status == .satisfied else { return }
        Self.logger.info("Network became available")
        scheduleTrigger()
    }

    /// Requests a reconnect after the debounce interval, collapsing bursts of events into one.
    func scheduleTrigger() {
        pendingTrigger?.cancel()
        pendingTrigger = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            self?.onReconnectNeeded?()
        }
    }
}
