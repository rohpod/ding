import Foundation
import NIOCore
import NIOIMAP
import NIOIMAPCore

// MARK: - Inbound Response Handler

/// Parsed container bundling a tagged command response along with correlated untagged and fetch payloads.
struct ParsedCommandResponse: Sendable {
    let tagged: TaggedResponse
    let untagged: [ResponsePayload]
    let fetchResponses: [FetchResponse]
}

/// Channel inbound handler that coordinates server responses with async/await callers.
///
/// Thread-safety is achieved via an `NSLock` protecting continuation and buffered response storage,
/// allowing safe synchronization between the NIO `EventLoop` thread and calling Swift Concurrency tasks.
final class IMAPResponseHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Response

    private let lock = NSLock()
    private var greetingContinuation: CheckedContinuation<Void, any Error>?
    private var activeCommandTag: String?
    private var pendingCommands: [String: CheckedContinuation<ParsedCommandResponse, any Error>] = [:]
    private var bufferedCommandResponses: [String: ParsedCommandResponse] = [:]
    private var untaggedBuffers: [String: [ResponsePayload]] = [:]
    private var fetchBuffers: [String: [FetchResponse]] = [:]
    private var cancelledCommandTags: Set<String> = []
    private var cancelledTagOrder: [String] = []
    private let maxCancelledTags = 64
    private var idleContinuation: AsyncThrowingStream<IdleEvent, any Error>.Continuation?
    private var idleStartContinuation: CheckedContinuation<Void, any Error>?
    private var caughtError: (any Error)?
    private var hasReceivedGreeting: Bool = false
    private var isChannelInactive: Bool = false
    /// Set when an `EXISTS`/`RECENT` arrives while no IDLE stream is registered, so it can be replayed on IDLE entry.
    private var pendingExists: Bool = false
    /// Set when the server's IDLE acknowledgement (`+ idling`) arrives before anyone is waiting for it.
    private var idleStartedEarly: Bool = false

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let response = self.unwrapInboundIn(data)
        switch response {
        case .tagged(let taggedResponse):
            lock.lock()
            if activeCommandTag == taggedResponse.tag {
                activeCommandTag = nil
            }
            let untagged = untaggedBuffers.removeValue(forKey: taggedResponse.tag) ?? []
            let fetches = fetchBuffers.removeValue(forKey: taggedResponse.tag) ?? []
            let parsed = ParsedCommandResponse(tagged: taggedResponse, untagged: untagged, fetchResponses: fetches)

            if let idleStart = idleStartContinuation {
                idleStartContinuation = nil
                lock.unlock()
                idleStart.resume(throwing: IMAPClientError.idleNotSupported)
                return
            }

            if let continuation = pendingCommands.removeValue(forKey: taggedResponse.tag) {
                lock.unlock()
                continuation.resume(returning: parsed)
            } else if cancelledCommandTags.remove(taggedResponse.tag) != nil {
                // Command was already cancelled/timed out; drop late response to prevent leak
                cancelledTagOrder.removeAll { $0 == taggedResponse.tag }
                lock.unlock()
            } else {
                bufferedCommandResponses[taggedResponse.tag] = parsed
                lock.unlock()
            }

        case .untagged(let payload):
            lock.lock()
            if !hasReceivedGreeting {
                hasReceivedGreeting = true
                let continuation = greetingContinuation
                greetingContinuation = nil
                lock.unlock()
                continuation?.resume()
            } else {
                if let tag = activeCommandTag {
                    untaggedBuffers[tag, default: []].append(payload)
                }
                switch payload {
                case .mailboxData(let mbData):
                    switch mbData {
                    case .exists:
                        // Only EXISTS announces a message arriving. RECENT repeats it, and FETCH merely reports
                        // flag changes (such as reading mail on another device), which are not new mail.
                        if let idle = idleContinuation {
                            idle.yield(.newMailAvailable)
                        } else {
                            pendingExists = true
                        }
                    default:
                        break
                    }
                default:
                    break
                }
                lock.unlock()
            }

        case .fetch(let fetchResponse):
            lock.lock()
            if let tag = activeCommandTag {
                fetchBuffers[tag, default: []].append(fetchResponse)
            }
            lock.unlock()

        case .idleStarted:
            lock.lock()
            let continuation = idleStartContinuation
            idleStartContinuation = nil
            if continuation == nil {
                // Acknowledged before `waitForIdleStart` registered; remember it so the wait returns at once.
                idleStartedEarly = true
            }
            lock.unlock()
            continuation?.resume()

        case .fatal(let responseText):
            let error = IMAPClientError.connectionFailed(
                underlying: NSError(
                    domain: "com.ding.mac.v3.imap",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Server closed connection: \(responseText.text)"]
                )
            )
            failAll(with: error)
            // After BYE the server is closing the connection; close our side too so the channel stops
            // looking usable (`isActive`) while every command is failing.
            context.close(promise: nil)

        case .authenticationChallenge:
            break
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        failAll(with: error)
        context.fireErrorCaught(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        lock.lock()
        isChannelInactive = true
        let existingError = caughtError
        lock.unlock()

        let fallback = existingError ?? IMAPClientError.connectionFailed(underlying: ChannelError.ioOnClosedChannel)
        failAll(with: fallback)
        context.fireChannelInactive()
    }

    func waitForGreeting() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                if let error = caughtError {
                    lock.unlock()
                    continuation.resume(throwing: error)
                    return
                }
                if isChannelInactive {
                    lock.unlock()
                    continuation.resume(throwing: IMAPClientError.connectionFailed(underlying: ChannelError.ioOnClosedChannel))
                    return
                }
                if hasReceivedGreeting {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                if Task.isCancelled {
                    // The cancellation handler already ran before this continuation existed.
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                greetingContinuation = continuation
                lock.unlock()
            }
        } onCancel: {
            self.cancelGreeting()
        }
    }

    func beginCommand(tag: String) {
        lock.lock()
        activeCommandTag = tag
        untaggedBuffers[tag] = []
        fetchBuffers[tag] = []
        if cancelledCommandTags.remove(tag) != nil {
            cancelledTagOrder.removeAll { $0 == tag }
        }
        lock.unlock()
    }

    func waitForCommand(tag: String) async throws -> ParsedCommandResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ParsedCommandResponse, any Error>) in
                lock.lock()
                if let error = caughtError {
                    lock.unlock()
                    continuation.resume(throwing: error)
                    return
                }
                if isChannelInactive {
                    lock.unlock()
                    continuation.resume(throwing: IMAPClientError.notConnected)
                    return
                }
                if let buffered = bufferedCommandResponses.removeValue(forKey: tag) {
                    lock.unlock()
                    continuation.resume(returning: buffered)
                    return
                }
                if Task.isCancelled {
                    // The cancellation handler already ran before this continuation existed.
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pendingCommands[tag] = continuation
                lock.unlock()
            }
        } onCancel: {
            self.cancel(tag: tag)
        }
    }

    func setIdleContinuation(_ continuation: AsyncThrowingStream<IdleEvent, any Error>.Continuation?) {
        lock.lock()
        idleContinuation = continuation
        if let continuation, pendingExists {
            // Mail was announced before IDLE was registered; replay it so the consumer fetches it.
            pendingExists = false
            continuation.yield(.newMailAvailable)
        }
        lock.unlock()
    }

    /// Forgets a stale IDLE acknowledgement before a new `IDLE` command is sent.
    func prepareForIdleStart() {
        lock.lock()
        idleStartedEarly = false
        lock.unlock()
    }

    /// Forgets any previously announced mailbox change. Called as a fetch begins, because that fetch
    /// is about to pick up everything the server has announced so far.
    func clearPendingExists() {
        lock.lock()
        pendingExists = false
        lock.unlock()
    }

    /// Ends the active IDLE event stream normally and clears it, waking any suspended consumer.
    func finishIdleContinuation() {
        lock.lock()
        let continuation = idleContinuation
        idleContinuation = nil
        lock.unlock()
        continuation?.finish()
    }

    func waitForIdleStart() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                if let error = caughtError {
                    lock.unlock()
                    continuation.resume(throwing: error)
                    return
                }
                if isChannelInactive {
                    lock.unlock()
                    continuation.resume(throwing: IMAPClientError.notConnected)
                    return
                }
                if idleStartedEarly {
                    idleStartedEarly = false
                    lock.unlock()
                    continuation.resume()
                    return
                }
                if Task.isCancelled {
                    // The cancellation handler already ran before this continuation existed.
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                idleStartContinuation = continuation
                lock.unlock()
            }
        } onCancel: {
            self.cancelIdleStart()
        }
    }

    private func cancelIdleStart() {
        lock.lock()
        let continuation = idleStartContinuation
        idleStartContinuation = nil
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }

    private func cancelGreeting() {
        lock.lock()
        let continuation = greetingContinuation
        greetingContinuation = nil
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }

    private func cancel(tag: String) {
        lock.lock()
        let continuation = pendingCommands.removeValue(forKey: tag)
        bufferedCommandResponses.removeValue(forKey: tag)
        untaggedBuffers.removeValue(forKey: tag)
        fetchBuffers.removeValue(forKey: tag)
        if activeCommandTag == tag {
            activeCommandTag = nil
        }
        if cancelledCommandTags.insert(tag).inserted {
            cancelledTagOrder.append(tag)
            if cancelledTagOrder.count > maxCancelledTags {
                let oldest = cancelledTagOrder.removeFirst()
                cancelledCommandTags.remove(oldest)
            }
        }
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }

    private func failAll(with error: any Error) {
        lock.lock()
        caughtError = error
        let greeting = greetingContinuation
        greetingContinuation = nil
        let idleStart = idleStartContinuation
        idleStartContinuation = nil
        let idle = idleContinuation
        idleContinuation = nil
        let commands = pendingCommands
        pendingCommands.removeAll()
        bufferedCommandResponses.removeAll()
        untaggedBuffers.removeAll()
        fetchBuffers.removeAll()
        cancelledCommandTags.removeAll()
        cancelledTagOrder.removeAll()
        activeCommandTag = nil
        lock.unlock()

        greeting?.resume(throwing: error)
        idleStart?.resume(throwing: error)
        idle?.finish(throwing: error)
        for (_, continuation) in commands {
            continuation.resume(throwing: error)
        }
    }
}
