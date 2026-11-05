import Foundation
import os
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
    private static let logger = Logger(subsystem: DingLog.subsystem, category: "IMAPClient")

    /// Shared single-threaded `EventLoopGroup` used across all client instances to minimize RAM and OS threads.
    public static let sharedEventLoopGroup: any EventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    /// Shared client TLS context. Creating an `NIOSSLContext` is expensive (it loads the system trust store and
    /// performs blocking disk I/O) and the type is documented as thread-safe, so it is built once and reused
    /// across every connection. Held as a `Result` so a creation failure still surfaces through `connect`.
    private static let sharedSSLContext: Result<NIOSSLContext, any Error> = Result {
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.minimumTLSVersion = .tlsv12
        return try NIOSSLContext(configuration: configuration)
    }

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

        Self.logger.info("Attempting IMAP connection to \(host, privacy: .private):\(port, privacy: .public)")

        do {
            try await withTimeout(seconds: 15) {
                try await self.performConnect(host: host, port: port)
            }
        } catch {
            await self.disconnect()
            let mapped = self.mapError(error)
            Self.logger.error("IMAP connection failed to \(host, privacy: .private): \(mapped.localizedDescription, privacy: .private)")
            throw mapped
        }

        Self.logger.info("Successfully connected and received greeting from \(host, privacy: .private)")
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

        Self.logger.info("Sending IMAP LOGIN command to \(self.currentHost ?? "server", privacy: .private)")

        let tag = nextTag()
        let command = Command.login(username: email, password: password)
        let taggedCommand = TaggedCommand(tag: tag, command: command)
        let message = IMAPClientHandler.Message.part(.tagged(taggedCommand))

        handler.beginCommand(tag: tag)

        do {
            let response = try await withTimeout(seconds: 15) {
                try await channel.writeAndFlush(message)
                return try await handler.waitForCommand(tag: tag)
            }

            switch response.tagged.state {
            case .ok:
                Self.logger.info("IMAP authentication succeeded for \(self.currentHost ?? "server", privacy: .private)")
            case .no(let responseText):
                Self.logger.warning("IMAP login rejected (NO) from \(self.currentHost ?? "server", privacy: .private): \(responseText.text, privacy: .private)")
                throw Self.classifyLoginRejection(responseText)
            case .bad(let responseText):
                Self.logger.warning("IMAP login rejected (BAD) from \(self.currentHost ?? "server", privacy: .private): \(responseText.text, privacy: .private)")
                throw Self.classifyLoginRejection(responseText)
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

        Self.logger.info("Disconnecting IMAP client from \(self.currentHost ?? "server", privacy: .private)")

        // Stop active IDLE if in progress
        if self.activeIdleTag != nil {
            try? await self.stopIdle()
        }

        // Best-effort graceful IMAP LOGOUT if channel is still active
        if channel.isActive, let handler = self.responseHandler {
            let tag = nextTag()
            let logoutCommand = TaggedCommand(tag: tag, command: .logout)
            let message = IMAPClientHandler.Message.part(.tagged(logoutCommand))

            handler.beginCommand(tag: tag)
            do {
                try await withTimeout(seconds: 3) {
                    try await channel.writeAndFlush(message)
                    _ = try await handler.waitForCommand(tag: tag)
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

        Self.logger.info("Selecting INBOX mailbox on \(self.currentHost ?? "server", privacy: .private)")

        let tag = nextTag()
        let command = Command.select(MailboxName.inbox)
        let taggedCommand = TaggedCommand(tag: tag, command: command)
        let message = IMAPClientHandler.Message.part(.tagged(taggedCommand))

        handler.beginCommand(tag: tag)

        do {
            let response = try await withTimeout(seconds: 15) {
                try await channel.writeAndFlush(message)
                return try await handler.waitForCommand(tag: tag)
            }

            switch response.tagged.state {
            case .ok:
                break
            case .no(let responseText):
                Self.logger.warning("SELECT INBOX failed (NO): \(responseText.text, privacy: .private)")
                throw IMAPClientError.selectFailed(responseText.text)
            case .bad(let responseText):
                Self.logger.warning("SELECT INBOX failed (BAD): \(responseText.text, privacy: .private)")
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

    /// The most messages whose envelope (sender and subject) is fetched for one batch of new mail.
    static let maxEnvelopesPerFetch = 5

    /// Fetches lightweight header summaries for messages with a UID greater than `sinceUID`.
    ///
    /// Done in two steps to bound memory and bandwidth no matter how large the backlog is: first only the UIDs
    /// (a few bytes each) for the whole backlog, then the envelope for the newest `maxEnvelopesPerFetch` messages,
    /// which is all a notification can name. Older messages in a larger batch keep empty sender and subject text.
    public func fetchNewMessages(sinceUID: UInt32) async throws -> [MessageSummary] {
        guard sinceUID < UInt32.max else {
            return []
        }

        Self.logger.info("Fetching new messages since UID \(sinceUID, privacy: .public)")

        // Everything the server has announced so far is picked up by the fetches below. Clearing once, before the
        // first step, keeps an EXISTS that arrives between the two steps pending instead of erasing it.
        responseHandler?.clearPendingExists()

        let backlog = UIDSet([UIDRange(UID(rawValue: sinceUID + 1)...)])
        let found = try await fetchMessages(matching: backlog, attributes: [.uid], sinceUID: sinceUID)

        let newest = found.suffix(Self.maxEnvelopesPerFetch)
        guard !newest.isEmpty else {
            return found
        }

        // The newest UIDs need not be contiguous, so address each one explicitly.
        let ranges = newest.map { UIDRange(UID(rawValue: $0.uid)...UID(rawValue: $0.uid)) }
        let detailed = try await fetchMessages(matching: UIDSet(ranges), attributes: [.uid, .envelope], sinceUID: sinceUID)
        return Self.mergeEnvelopes(into: found, details: detailed)
    }

    /// Replaces each summary in `found` with the detailed summary for the same UID, when one was fetched.
    ///
    /// The full list is kept, because the caller derives its high-water mark from the largest UID. A UID missing
    /// from `details` (for example expunged between the two fetches) keeps its empty entry.
    static func mergeEnvelopes(into found: [MessageSummary], details: [MessageSummary]) -> [MessageSummary] {
        let detailsByUID = Dictionary(details.map { ($0.uid, $0) }, uniquingKeysWith: { _, latest in latest })
        return found.map { detailsByUID[$0.uid] ?? $0 }
    }

    /// Issues one `UID FETCH` and parses the untagged `FETCH` responses into summaries (ascending by UID).
    private func fetchMessages(
        matching uidSet: UIDSet,
        attributes: [FetchAttribute],
        sinceUID: UInt32
    ) async throws -> [MessageSummary] {
        guard self.isConnected, let channel = self.channel, let handler = self.responseHandler else {
            throw IMAPClientError.notConnected
        }

        let tag = nextTag()
        guard let command = Command.uidFetch(
            messages: uidSet,
            attributes: attributes,
            modifiers: []
        ) else {
            return []
        }

        let taggedCommand = TaggedCommand(tag: tag, command: command)
        let message = IMAPClientHandler.Message.part(.tagged(taggedCommand))

        handler.beginCommand(tag: tag)

        do {
            let response = try await withTimeout(seconds: 20) {
                try await channel.writeAndFlush(message)
                return try await handler.waitForCommand(tag: tag)
            }

            switch response.tagged.state {
            case .ok:
                break
            case .no(let responseText):
                Self.logger.warning("UID FETCH failed (NO): \(responseText.text, privacy: .private)")
                throw IMAPClientError.unexpectedResponse("UID FETCH rejected: \(responseText.text)")
            case .bad(let responseText):
                Self.logger.warning("UID FETCH failed (BAD): \(responseText.text, privacy: .private)")
                throw IMAPClientError.unexpectedResponse("UID FETCH syntax error: \(responseText.text)")
            }

            var summaries: [MessageSummary] = []
            var currentUID: UInt32?
            var currentEnvelope: Envelope?

            func flushCurrent() {
                // "n:*" always includes the highest message even when its UID is below n, so filter explicitly.
                if let uid = currentUID, uid > sinceUID {
                    let subject = RFC2047Decoder.decode(currentEnvelope?.subject.flatMap { String(buffer: $0) } ?? "")
                    let from = currentEnvelope == nil ? "" : self.formatFrom(currentEnvelope?.from)
                    summaries.append(MessageSummary(uid: uid, subject: subject, from: from, dateReceived: Date()))
                }
                currentUID = nil
                currentEnvelope = nil
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

    /// Queries the total number of unread (unseen) messages in the primary inbox.
    public func fetchUnreadCount() async throws -> Int {
        guard self.isConnected, let channel = self.channel, let handler = self.responseHandler else {
            throw IMAPClientError.notConnected
        }

        Self.logger.info("Fetching unread count for INBOX on \(self.currentHost ?? "server", privacy: .private)")

        let tag = nextTag()
        let command = Command.status(MailboxName.inbox, [.unseenCount])
        let taggedCommand = TaggedCommand(tag: tag, command: command)
        let message = IMAPClientHandler.Message.part(.tagged(taggedCommand))

        handler.beginCommand(tag: tag)

        do {
            let response = try await withTimeout(seconds: 15) {
                try await channel.writeAndFlush(message)
                return try await handler.waitForCommand(tag: tag)
            }

            switch response.tagged.state {
            case .ok:
                break
            case .no(let responseText):
                Self.logger.warning("STATUS INBOX failed (NO): \(responseText.text, privacy: .private)")
                throw IMAPClientError.unexpectedResponse("STATUS INBOX rejected: \(responseText.text)")
            case .bad(let responseText):
                Self.logger.warning("STATUS INBOX failed (BAD): \(responseText.text, privacy: .private)")
                throw IMAPClientError.unexpectedResponse("STATUS INBOX syntax error: \(responseText.text)")
            }

            var unseenCount: Int?

            for untagged in response.untagged {
                switch untagged {
                case .mailboxData(let data):
                    switch data {
                    case .status(let mailboxName, let status):
                        if mailboxName.isInbox {
                            unseenCount = status.unseenCount
                        }
                    default:
                        break
                    }
                default:
                    break
                }
            }

            // A reply without the count must not be reported as "0 unread": that would tell the user their
            // inbox is empty when the check actually failed.
            guard let resolvedCount = unseenCount else {
                throw IMAPClientError.unexpectedResponse("STATUS INBOX reply did not include an unseen count")
            }
            Self.logger.info("STATUS INBOX returned \(resolvedCount, privacy: .public) unread message(s)")
            return resolvedCount
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
            let response = try await withTimeout(seconds: 10) {
                try await channel.writeAndFlush(message)
                return try await handler.waitForCommand(tag: tag)
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
            // Do not downgrade to polling just because CAPABILITY failed: this is a connection problem, and the
            // caller should reconnect rather than conclude the server lacks IDLE.
            if error is CancellationError { throw IMAPClientError.timeout }
            throw self.mapError(error)
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

        handler.prepareForIdleStart()
        handler.setIdleContinuation(streamContinuation)

        do {
            try await channel.writeAndFlush(message)
            // 15-second timeout for server to acknowledge IDLE start (+ idling)
            try await withTimeout(seconds: 15) {
                try await handler.waitForIdleStart()
            }
            Self.logger.info("IMAP IDLE stream established for tag \(tag, privacy: .public)")
            return stream
        } catch {
            Self.logger.error("Failed to start IMAP IDLE: \(error.localizedDescription, privacy: .private)")
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
            try await withTimeout(seconds: 10) {
                try await channel.writeAndFlush(message)
                _ = try await handler.waitForCommand(tag: tag)
            }
        } catch {
            // A server that never acknowledges DONE usually means a dead socket. Surface the failure so the
            // worker reconnects instead of carrying on as if IDLE had ended cleanly.
            Self.logger.warning("Error stopping IDLE: \(error.localizedDescription, privacy: .private)")
            handler.finishIdleContinuation()
            throw self.mapError(error)
        }

        // Finish (not just drop) the stream so any consumer suspended on it wakes up and can resume IDLE.
        handler.finishIdleContinuation()
        Self.logger.info("IMAP IDLE session ended")
    }

    /// Maps a rejected `LOGIN` to an error, using the response code (RFC 5530) when the server supplies one.
    ///
    /// Only an explicit authentication or authorization code is treated as proof that the credentials are bad.
    /// Codes describing server-side conditions are retryable, and a bare `NO` is ambiguous: some providers
    /// use it for both wrong passwords and temporary policy rejections.
    static func classifyLoginRejection(_ responseText: ResponseText) -> IMAPClientError {
        switch responseText.code {
        case .some(.authenticationFailed), .some(.authorizationFailed), .some(.expired):
            return .authenticationFailed
        case .some(.unavailable), .some(.limit), .some(.inUse), .some(.serverBug), .some(.cannot):
            return .temporarilyUnavailable(responseText.text)
        default:
            return .loginRejected(responseText.text)
        }
    }

    // MARK: - Internal Message Parsing Helpers

    private func formatFrom(_ fromList: [EmailAddressListElement]?) -> String {
        guard let fromList = fromList, let first = fromList.first else {
            return "Unknown Sender"
        }

        switch first {
        case .singleAddress(let address):
            let person = address.personName.flatMap { RFC2047Decoder.decode(String(buffer: $0)) }?.trimmingCharacters(in: .whitespacesAndNewlines)
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
            return RFC2047Decoder.decode(String(buffer: group.groupName))
        }
    }

    // MARK: - Internal Connection Setup

    private func performConnect(host: String, port: Int) async throws {
        let handler = IMAPResponseHandler()
        let sslContext = try Self.sharedSSLContext.get()

        let bootstrap = ClientBootstrap(group: self.eventLoopGroup)
            .connectTimeout(.seconds(15))
            .channelOption(ChannelOptions.socketOption(.so_keepalive), value: 1)
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

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw IMAPClientError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
