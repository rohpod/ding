import Foundation
import os
import NIO
import NIOCore
import NIOPosix
import NIOSSL
import NIOIMAP
import NIOIMAPCore

/// Production implementation of `IMAPConnecting` backed by SwiftNIO, NIOSSL, and NIOIMAP.
///
/// ## Swift 6 Strict Concurrency & Actor Isolation
/// Managing mutable connection state across asynchronous network operations requires strict thread-safety.
/// `NIOIMAPClient` is implemented as an `actor` to guarantee that channel references, sequence numbers,
/// and in-flight command states are serialized and protected against concurrent data races.
///
/// ## NIO-to-Async Bridging Architecture
/// SwiftNIO's I/O model is fundamentally built upon `EventLoopGroup`, `ChannelPipeline`, and callback/promise-based
/// abstractions (`EventLoopFuture`). Bridging this to Swift 6 structured concurrency (`async`/`await`) involves:
/// 1. `withCheckedThrowingContinuation` to suspend Swift Concurrency tasks until NIO channel operations complete.
/// 2. `withTaskCancellationHandler` to ensure that task cancellations and timeout expirations immediately
///    resume continuations with appropriate errors rather than leaking memory or hanging forever.
/// 3. `IMAPResponseHandler`, a thread-safe inbound handler marked `@unchecked Sendable` synchronized via `NSLock`,
///    which buffers and routes incoming parsed IMAP responses to waiting continuations matched by command tag.
///
/// ## RAM Efficiency & Shared EventLoopGroup
/// Ding is a lightweight macOS menu bar utility designed to run 24/7 in the background with minimal RAM usage.
/// Each `MultiThreadedEventLoopGroup` allocates native OS threads, execution stacks, and kqueue descriptors.
/// Creating an `EventLoopGroup` per connection would multiply memory footprint and thread count.
/// Because SwiftNIO provides non-blocking asynchronous multiplexing, a single thread can easily handle all IMAP
/// connections for the application (polling, IDLE push, and ad-hoc credential verification).
/// `NIOIMAPClient` therefore defaults to sharing `NIOIMAPClient.sharedEventLoopGroup`.
///
/// ## Privacy-Conscious Logging
/// In accordance with Ding's security model, credentials (email addresses and App Passwords) are strictly excluded
/// from all logging statements, even at `.debug` level. Diagnostics log only operation types, server endpoints,
/// and error classifications to ensure zero sensitive user data is exposed in macOS system logs (`log stream`).
public actor NIOIMAPClient: IMAPConnecting {
    private static let logger = Logger(subsystem: "com.ding.mac", category: "IMAPClient")

    /// Shared single-threaded `EventLoopGroup` used across all client instances to minimize RAM and OS threads.
    public static let sharedEventLoopGroup: any EventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    private let eventLoopGroup: any EventLoopGroup
    private let ownsEventLoopGroup: Bool

    private var channel: (any Channel)?
    private var responseHandler: IMAPResponseHandler?
    private var currentHost: String?
    private var currentPort: Int?
    private var commandTagCounter: UInt64 = 0
    private var activeIdleTag: String?

    /// Indicates whether the client maintains an active network connection to the IMAP server.
    public var isConnected: Bool {
        guard let channel = self.channel else {
            return false
        }
        return channel.isActive
    }

    /// Initializes a new NIO-backed IMAP client.
    ///
    /// - Parameters:
    ///   - eventLoopGroup: Optional `EventLoopGroup` to use. If `nil`, defaults to `NIOIMAPClient.sharedEventLoopGroup`.
    ///   - ownsEventLoopGroup: If `true`, the client will shut down the event loop group upon `disconnect()`. Defaults to `false`.
    public init(eventLoopGroup: (any EventLoopGroup)? = nil, ownsEventLoopGroup: Bool = false) {
        if let injected = eventLoopGroup {
            self.eventLoopGroup = injected
            self.ownsEventLoopGroup = ownsEventLoopGroup
        } else {
            self.eventLoopGroup = Self.sharedEventLoopGroup
            self.ownsEventLoopGroup = false
        }
    }

    deinit {
        channel?.close(promise: nil)
    }

    /// Establishes a TLS connection to the IMAP server and awaits the initial server greeting.
    ///
    /// - Parameters:
    ///   - host: The server hostname (e.g., `"imap.gmail.com"`).
    ///   - port: The server port (typically `993` for implicit TLS).
    /// - Throws: `IMAPClientError` describing the failure reason if the connection cannot be established.
    public func connect(host: String, port: Int) async throws {
        if isConnected {
            await disconnect()
        }

        Self.logger.info("Attempting IMAP connection to \(host, privacy: .public):\(port, privacy: .public)")

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await self.performConnect(host: host, port: port)
                }
                group.addTask {
                    // 15-second connection timeout
                    try await Task.sleep(nanoseconds: 15_000_000_000)
                    throw IMAPClientError.timeout
                }
                try await group.next()
                group.cancelAll()
            }
        } catch {
            await self.disconnect()
            let mapped = self.mapError(error)
            Self.logger.error("IMAP connection failed to \(host, privacy: .public): \(mapped.localizedDescription, privacy: .public)")
            throw mapped
        }

        Self.logger.info("Successfully connected and received greeting from \(host, privacy: .public)")
    }

    /// Authenticates with the IMAP server using the provided credentials via IMAP `LOGIN`.
    ///
    /// - Parameters:
    ///   - email: The account email / username.
    ///   - password: The IMAP app password.
    /// - Throws: `IMAPClientError.notConnected`, `IMAPClientError.authenticationFailed`, or other `IMAPClientError`s.
    public func login(email: String, password: String) async throws {
        guard self.isConnected, let channel = self.channel, let handler = self.responseHandler else {
            throw IMAPClientError.notConnected
        }

        Self.logger.info("Sending IMAP LOGIN command to \(self.currentHost ?? "server", privacy: .public)")

        let tag = nextTag()
        let command = Command.login(username: email, password: password)
        let taggedCommand = TaggedCommand(tag: tag, command: command)
        let message = IMAPClientHandler.Message.part(.tagged(taggedCommand))

        handler.beginCommand(tag: tag)

        do {
            let response = try await withThrowingTaskGroup(of: ParsedCommandResponse.self) { group in
                group.addTask {
                    try await channel.writeAndFlush(message)
                    return try await handler.waitForCommand(tag: tag)
                }
                group.addTask {
                    // 15-second command timeout
                    try await Task.sleep(nanoseconds: 15_000_000_000)
                    throw IMAPClientError.timeout
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }

            switch response.tagged.state {
            case .ok:
                Self.logger.info("IMAP authentication succeeded for \(self.currentHost ?? "server", privacy: .public)")
            case .no(let responseText):
                Self.logger.warning("IMAP authentication failed (NO) from \(self.currentHost ?? "server", privacy: .public): \(responseText.text, privacy: .public)")
                throw IMAPClientError.authenticationFailed
            case .bad(let responseText):
                Self.logger.warning("IMAP authentication failed (BAD) from \(self.currentHost ?? "server", privacy: .public): \(responseText.text, privacy: .public)")
                throw IMAPClientError.authenticationFailed
            }
        } catch let clientError as IMAPClientError {
            throw clientError
        } catch is CancellationError {
            throw IMAPClientError.timeout
        } catch {
            let mapped = self.mapError(error)
            throw mapped
        }
    }

    /// Cleanly closes the IMAP connection, issuing a `LOGOUT` command if the channel remains active.
    public func disconnect() async {
        guard let channel = self.channel else {
            return
        }

        Self.logger.info("Disconnecting IMAP client from \(self.currentHost ?? "server", privacy: .public)")

        // Stop active IDLE if in progress
        if self.activeIdleTag != nil {
            self.activeIdleTag = nil
            self.responseHandler?.setIdleContinuation(nil)
            let doneMessage = IMAPClientHandler.Message.part(.idleDone)
            try? await channel.writeAndFlush(doneMessage)
        }

        // Best-effort graceful IMAP LOGOUT if channel is still active
        if channel.isActive, let handler = self.responseHandler {
            let tag = nextTag()
            let logoutCommand = TaggedCommand(tag: tag, command: .logout)
            let message = IMAPClientHandler.Message.part(.tagged(logoutCommand))

            handler.beginCommand(tag: tag)
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        try await channel.writeAndFlush(message)
                        _ = try await handler.waitForCommand(tag: tag)
                    }
                    group.addTask {
                        // 3-second grace window for LOGOUT response
                        try await Task.sleep(nanoseconds: 3_000_000_000)
                        throw IMAPClientError.timeout
                    }
                    _ = try await group.next()
                    group.cancelAll()
                }
            } catch {
                Self.logger.debug("IMAP LOGOUT completed or timed out during disconnect")
            }
        }

        try? await channel.close()

        self.channel = nil
        self.responseHandler = nil
        self.currentHost = nil
        self.currentPort = nil
        self.activeIdleTag = nil

        if ownsEventLoopGroup {
            try? await eventLoopGroup.shutdownGracefully()
        }

        Self.logger.info("IMAP client disconnected")
    }

    /// Issues an IMAP `SELECT INBOX` command to select the primary inbox and retrieve its mailbox status.
    public func selectInbox() async throws -> MailboxStatus {
        guard self.isConnected, let channel = self.channel, let handler = self.responseHandler else {
            throw IMAPClientError.notConnected
        }

        Self.logger.info("Selecting INBOX mailbox on \(self.currentHost ?? "server", privacy: .public)")

        let tag = nextTag()
        let command = Command.select(MailboxName.inbox)
        let taggedCommand = TaggedCommand(tag: tag, command: command)
        let message = IMAPClientHandler.Message.part(.tagged(taggedCommand))

        handler.beginCommand(tag: tag)

        do {
            let response = try await withThrowingTaskGroup(of: ParsedCommandResponse.self) { group in
                group.addTask {
                    try await channel.writeAndFlush(message)
                    return try await handler.waitForCommand(tag: tag)
                }
                group.addTask {
                    // 15-second timeout for SELECT
                    try await Task.sleep(nanoseconds: 15_000_000_000)
                    throw IMAPClientError.timeout
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }

            switch response.tagged.state {
            case .ok:
                break
            case .no(let responseText):
                Self.logger.warning("SELECT INBOX failed (NO): \(responseText.text, privacy: .public)")
                throw IMAPClientError.selectFailed(responseText.text)
            case .bad(let responseText):
                Self.logger.warning("SELECT INBOX failed (BAD): \(responseText.text, privacy: .public)")
                throw IMAPClientError.selectFailed(responseText.text)
            }

            var uidValidity: UInt32?
            var uidNext: UInt32?
            var messageCount: UInt32?
            var recentCount: UInt32?

            for untagged in response.untagged {
                switch untagged {
                case .conditionalState(let status):
                    switch status {
                    case .ok(let responseText):
                        if let code = responseText.code {
                            switch code {
                            case .uidValidity(let uv):
                                uidValidity = UInt32(uv)
                            case .uidNext(let un):
                                uidNext = un.rawValue
                            default:
                                break
                            }
                        }
                    default:
                        break
                    }
                case .mailboxData(let data):
                    switch data {
                    case .exists(let count):
                        messageCount = UInt32(count)
                    case .recent(let count):
                        recentCount = UInt32(count)
                    default:
                        break
                    }
                default:
                    break
                }
            }

            guard let resolvedValidity = uidValidity else {
                Self.logger.error("SELECT INBOX response missing UIDVALIDITY")
                throw IMAPClientError.selectFailed("Mailbox response missing UIDVALIDITY")
            }

            let resolvedNext = uidNext ?? ((messageCount ?? 0) > 0 ? (messageCount! + 1) : 1)

            let status = MailboxStatus(
                uidValidity: resolvedValidity,
                uidNext: resolvedNext,
                messageCount: messageCount,
                recentCount: recentCount
            )

            Self.logger.info("SELECT INBOX succeeded: uidValidity=\(status.uidValidity, privacy: .public), uidNext=\(status.uidNext, privacy: .public), count=\(status.messageCount ?? 0, privacy: .public)")
            return status
        } catch let clientError as IMAPClientError {
            throw clientError
        } catch is CancellationError {
            throw IMAPClientError.timeout
        } catch {
            let mapped = self.mapError(error)
            throw mapped
        }
    }

    /// Fetches lightweight header summaries for messages with a UID greater than `sinceUID`.
    public func fetchNewMessages(sinceUID: UInt32) async throws -> [MessageSummary] {
        guard self.isConnected, let channel = self.channel, let handler = self.responseHandler else {
            throw IMAPClientError.notConnected
        }

        guard sinceUID < UInt32.max else {
            return []
        }

        Self.logger.info("Fetching new messages since UID \(sinceUID, privacy: .public)")

        let tag = nextTag()
        let range = UIDRange(UID(rawValue: sinceUID + 1)...)
        let uidSet = UIDSet([range])
        guard let command = Command.uidFetch(
            messages: uidSet,
            attributes: [.uid, .envelope, .internalDate],
            modifiers: []
        ) else {
            return []
        }

        let taggedCommand = TaggedCommand(tag: tag, command: command)
        let message = IMAPClientHandler.Message.part(.tagged(taggedCommand))

        handler.beginCommand(tag: tag)

        do {
            let response = try await withThrowingTaskGroup(of: ParsedCommandResponse.self) { group in
                group.addTask {
                    try await channel.writeAndFlush(message)
                    return try await handler.waitForCommand(tag: tag)
                }
                group.addTask {
                    // 20-second timeout for UID FETCH
                    try await Task.sleep(nanoseconds: 20_000_000_000)
                    throw IMAPClientError.timeout
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }

            switch response.tagged.state {
            case .ok:
                break
            case .no(let responseText):
                Self.logger.warning("UID FETCH failed (NO): \(responseText.text, privacy: .public)")
                throw IMAPClientError.unexpectedResponse("UID FETCH rejected: \(responseText.text)")
            case .bad(let responseText):
                Self.logger.warning("UID FETCH failed (BAD): \(responseText.text, privacy: .public)")
                throw IMAPClientError.unexpectedResponse("UID FETCH syntax error: \(responseText.text)")
            }

            var summaries: [MessageSummary] = []
            var currentUID: UInt32?
            var currentEnvelope: Envelope?
            var currentDate: Date?

            func flushCurrent() {
                if let uid = currentUID, uid > sinceUID {
                    let subject = currentEnvelope?.subject.flatMap { String(buffer: $0) } ?? ""
                    let from = self.formatFrom(currentEnvelope?.from)
                    let date = currentDate ?? self.parseEnvelopeDate(currentEnvelope?.date) ?? Date()
                    summaries.append(MessageSummary(uid: uid, subject: subject, from: from, dateReceived: date))
                }
                currentUID = nil
                currentEnvelope = nil
                currentDate = nil
            }

            for fetchPart in response.fetchResponses {
                switch fetchPart {
                case .start:
                    flushCurrent()
                case .startUID(let uid):
                    flushCurrent()
                    currentUID = uid.rawValue
                case .simpleAttribute(let attr):
                    switch attr {
                    case .uid(let uid):
                        currentUID = uid.rawValue
                    case .envelope(let envelope):
                        currentEnvelope = envelope
                    case .internalDate(let serverDate):
                        var dc = DateComponents()
                        let c = serverDate.components
                        dc.year = c.year
                        dc.month = c.month
                        dc.day = c.day
                        dc.hour = c.hour
                        dc.minute = c.minute
                        dc.second = c.second
                        dc.timeZone = TimeZone(secondsFromGMT: c.zoneMinutes * 60)
                        currentDate = Calendar(identifier: .gregorian).date(from: dc)
                    default:
                        break
                    }
                case .finish:
                    flushCurrent()
                default:
                    break
                }
            }
            flushCurrent()

            summaries.sort(by: { $0.uid < $1.uid })
            Self.logger.info("UID FETCH returned \(summaries.count, privacy: .public) new message(s)")
            return summaries
        } catch let clientError as IMAPClientError {
            throw clientError
        } catch is CancellationError {
            throw IMAPClientError.timeout
        } catch {
            let mapped = self.mapError(error)
            throw mapped
        }
    }

    /// Queries the server capabilities to determine if the `IDLE` extension (RFC 2177) is supported.
    public func supportsIdle() async throws -> Bool {
        guard self.isConnected, let channel = self.channel, let handler = self.responseHandler else {
            throw IMAPClientError.notConnected
        }

        let tag = nextTag()
        let command = Command.capability
        let taggedCommand = TaggedCommand(tag: tag, command: command)
        let message = IMAPClientHandler.Message.part(.tagged(taggedCommand))

        handler.beginCommand(tag: tag)

        do {
            let response = try await withThrowingTaskGroup(of: ParsedCommandResponse.self) { group in
                group.addTask {
                    try await channel.writeAndFlush(message)
                    return try await handler.waitForCommand(tag: tag)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                    throw IMAPClientError.timeout
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }

            for untagged in response.untagged {
                if case .capabilityData(let caps) = untagged {
                    if caps.contains(where: { $0.name.caseInsensitiveCompare("IDLE") == .orderedSame }) {
                        return true
                    }
                }
            }

            if case .ok(let text) = response.tagged.state, let code = text.code, case .capability(let caps) = code {
                if caps.contains(where: { $0.name.caseInsensitiveCompare("IDLE") == .orderedSame }) {
                    return true
                }
            }

            return false
        } catch {
            return false
        }
    }

    /// Starts an IMAP `IDLE` session and returns an asynchronous stream of untagged server events.
    public func startIdle() async throws -> AsyncThrowingStream<IdleEvent, any Error> {
        guard self.isConnected, let channel = self.channel, let handler = self.responseHandler else {
            throw IMAPClientError.notConnected
        }

        let isSupported = try await supportsIdle()
        guard isSupported else {
            throw IMAPClientError.idleNotSupported
        }

        let tag = nextTag()
        self.activeIdleTag = tag
        let command = Command.idleStart
        let taggedCommand = TaggedCommand(tag: tag, command: command)
        let message = IMAPClientHandler.Message.part(.tagged(taggedCommand))

        var streamContinuation: AsyncThrowingStream<IdleEvent, any Error>.Continuation!
        let stream = AsyncThrowingStream<IdleEvent, any Error> { continuation in
            streamContinuation = continuation
        }

        handler.setIdleContinuation(streamContinuation)

        do {
            try await channel.writeAndFlush(message)
            // 15-second timeout for server to acknowledge IDLE start (+ idling)
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await handler.waitForIdleStart()
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 15_000_000_000)
                    throw IMAPClientError.timeout
                }
                try await group.next()
                group.cancelAll()
            }
            Self.logger.info("IMAP IDLE stream established for tag \(tag, privacy: .public)")
            return stream
        } catch {
            Self.logger.error("Failed to start IMAP IDLE: \(error.localizedDescription, privacy: .public)")
            handler.setIdleContinuation(nil)
            streamContinuation.finish(throwing: error)
            self.activeIdleTag = nil
            throw error
        }
    }

    /// Cleanly terminates an active IMAP `IDLE` session by sending the `DONE` continuation token.
    public func stopIdle() async throws {
        guard self.isConnected, let channel = self.channel, let handler = self.responseHandler else {
            throw IMAPClientError.notConnected
        }

        guard let tag = self.activeIdleTag else {
            return
        }

        Self.logger.info("Stopping IMAP IDLE for tag \(tag, privacy: .public)")
        self.activeIdleTag = nil
        let message = IMAPClientHandler.Message.part(.idleDone)

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await channel.writeAndFlush(message)
                    _ = try await handler.waitForCommand(tag: tag)
                }
                group.addTask {
                    // 10-second timeout for IDLE DONE tagged response
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                    throw IMAPClientError.timeout
                }
                try await group.next()
                group.cancelAll()
            }
        } catch {
            Self.logger.warning("Error stopping IDLE: \(error.localizedDescription, privacy: .public)")
        }

        handler.setIdleContinuation(nil)
        Self.logger.info("IMAP IDLE session ended")
    }

    // MARK: - Internal Message Parsing Helpers

    private func formatFrom(_ fromList: [EmailAddressListElement]?) -> String {
        guard let fromList = fromList, let first = fromList.first else {
            return "Unknown Sender"
        }

        switch first {
        case .singleAddress(let address):
            let person = address.personName.flatMap { String(buffer: $0) }?.trimmingCharacters(in: .whitespacesAndNewlines)
            let mailbox = address.mailbox.flatMap { String(buffer: $0) }?.trimmingCharacters(in: .whitespacesAndNewlines)
            let host = address.host.flatMap { String(buffer: $0) }?.trimmingCharacters(in: .whitespacesAndNewlines)

            let email: String?
            if let mb = mailbox, let h = host, !mb.isEmpty, !h.isEmpty {
                email = "\(mb)@\(h)"
            } else {
                email = mailbox ?? host
            }

            if let p = person, !p.isEmpty {
                if let e = email, !e.isEmpty {
                    return "\(p) <\(e)>"
                }
                return p
            } else if let e = email, !e.isEmpty {
                return e
            }
            return "Unknown Sender"

        case .group(let group):
            return String(buffer: group.groupName)
        }
    }

    private func parseEnvelopeDate(_ messageDate: InternetMessageDate?) -> Date? {
        guard let messageDate = messageDate else { return nil }
        let raw = String(messageDate)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        if let d = formatter.date(from: raw) { return d }
        formatter.dateFormat = "dd MMM yyyy HH:mm:ss Z"
        if let d = formatter.date(from: raw) { return d }
        return nil
    }

    // MARK: - Internal Connection Setup

    private func performConnect(host: String, port: Int) async throws {
        let handler = IMAPResponseHandler()
        let sslContext = try NIOSSLContext(configuration: .makeClientConfiguration())

        let bootstrap = ClientBootstrap(group: self.eventLoopGroup)
            .connectTimeout(.seconds(15))
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    // Port 993 implies implicit TLS. NIOSSLClientHandler initiates TLS immediately.
                    let sslHandler = try NIOSSLClientHandler(context: sslContext, serverHostname: host)
                    let imapHandler = IMAPClientHandler()
                    try channel.pipeline.syncOperations.addHandler(sslHandler)
                    try channel.pipeline.syncOperations.addHandler(imapHandler)
                    try channel.pipeline.syncOperations.addHandler(handler)
                }
            }

        let newChannel: any Channel
        do {
            newChannel = try await bootstrap.connect(host: host, port: port).get()
        } catch {
            throw self.mapError(error)
        }

        self.channel = newChannel
        self.responseHandler = handler
        self.currentHost = host
        self.currentPort = port

        // Per RFC 3501 Section 2.1, wait for the server greeting before issuing commands.
        do {
            try await handler.waitForGreeting()
        } catch {
            try? await newChannel.close()
            self.channel = nil
            self.responseHandler = nil
            self.currentHost = nil
            self.currentPort = nil
            throw self.mapError(error)
        }
    }

    private func nextTag() -> String {
        commandTagCounter += 1
        return "d\(commandTagCounter)"
    }

    private func mapError(_ error: any Error) -> IMAPClientError {
        if let clientError = error as? IMAPClientError {
            return clientError
        }
        if let sslError = error as? NIOSSLError {
            return .tlsHandshakeFailed(underlying: sslError)
        }
        if let boringError = error as? BoringSSLError {
            return .tlsHandshakeFailed(underlying: boringError)
        }
        if let channelError = error as? ChannelError {
            switch channelError {
            case .connectTimeout:
                return .timeout
            default:
                return .connectionFailed(underlying: channelError)
            }
        }
        let errorDescription = String(describing: error).lowercased()
        if errorDescription.contains("ssl") || errorDescription.contains("tls") ||
           errorDescription.contains("handshake") || errorDescription.contains("certificate") {
            return .tlsHandshakeFailed(underlying: error)
        }
        return .connectionFailed(underlying: error)
    }
}

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
private final class IMAPResponseHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Response

    private let lock = NSLock()
    private var greetingContinuation: CheckedContinuation<Void, any Error>?
    private var activeCommandTag: String?
    private var pendingCommands: [String: CheckedContinuation<ParsedCommandResponse, any Error>] = [:]
    private var bufferedCommandResponses: [String: ParsedCommandResponse] = [:]
    private var untaggedBuffers: [String: [ResponsePayload]] = [:]
    private var fetchBuffers: [String: [FetchResponse]] = [:]
    private var idleContinuation: AsyncThrowingStream<IdleEvent, any Error>.Continuation?
    private var idleStartContinuation: CheckedContinuation<Void, any Error>?
    private var caughtError: (any Error)?
    private var hasReceivedGreeting: Bool = false
    private var isChannelInactive: Bool = false

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
                if let idle = idleContinuation {
                    switch payload {
                    case .mailboxData(let mbData):
                        switch mbData {
                        case .exists, .recent:
                            idle.yield(.newMailAvailable)
                        default:
                            break
                        }
                    default:
                        break
                    }
                }
                lock.unlock()
            }

        case .fetch(let fetchResponse):
            lock.lock()
            if let tag = activeCommandTag {
                fetchBuffers[tag, default: []].append(fetchResponse)
            }
            if let idle = idleContinuation {
                idle.yield(.newMailAvailable)
            }
            lock.unlock()

        case .idleStarted:
            lock.lock()
            let continuation = idleStartContinuation
            idleStartContinuation = nil
            lock.unlock()
            continuation?.resume()

        case .fatal(let responseText):
            let error = IMAPClientError.connectionFailed(
                underlying: NSError(
                    domain: "com.ding.mac.imap",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Server closed connection: \(responseText.text)"]
                )
            )
            failAll(with: error)

        case .authenticationChallenge:
            break
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        failAll(with: error)
        context.fireErrorCaught(error)
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
        lock.unlock()
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
