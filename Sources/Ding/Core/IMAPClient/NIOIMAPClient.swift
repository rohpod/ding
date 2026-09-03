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

        do {
            let response = try await withThrowingTaskGroup(of: TaggedResponse.self) { group in
                group.addTask {
                    try await channel.writeAndFlush(message)
                    return try await handler.waitForResponse(tag: tag)
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

            switch response.state {
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

        // Best-effort graceful IMAP LOGOUT if channel is still active
        if channel.isActive, let handler = self.responseHandler {
            let tag = nextTag()
            let logoutCommand = TaggedCommand(tag: tag, command: .logout)
            let message = IMAPClientHandler.Message.part(.tagged(logoutCommand))

            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        try await channel.writeAndFlush(message)
                        _ = try await handler.waitForResponse(tag: tag)
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

        if ownsEventLoopGroup {
            try? await eventLoopGroup.shutdownGracefully()
        }

        Self.logger.info("IMAP client disconnected")
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

/// Channel inbound handler that coordinates server responses with async/await callers.
///
/// Thread-safety is achieved via an `NSLock` protecting continuation and buffered response storage,
/// allowing safe synchronization between the NIO `EventLoop` thread and calling Swift Concurrency tasks.
private final class IMAPResponseHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Response

    private let lock = NSLock()
    private var greetingContinuation: CheckedContinuation<Void, any Error>?
    private var pendingCommands: [String: CheckedContinuation<TaggedResponse, any Error>] = [:]
    private var bufferedResponses: [String: TaggedResponse] = [:]
    private var caughtError: (any Error)?
    private var hasReceivedGreeting: Bool = false
    private var isChannelInactive: Bool = false

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let response = self.unwrapInboundIn(data)
        switch response {
        case .tagged(let taggedResponse):
            lock.lock()
            if let continuation = pendingCommands.removeValue(forKey: taggedResponse.tag) {
                lock.unlock()
                continuation.resume(returning: taggedResponse)
            } else {
                bufferedResponses[taggedResponse.tag] = taggedResponse
                lock.unlock()
            }

        case .untagged:
            // The initial server greeting is an untagged OK response (RFC 3501 Section 7.1.1).
            lock.lock()
            if !hasReceivedGreeting {
                hasReceivedGreeting = true
                let continuation = greetingContinuation
                greetingContinuation = nil
                lock.unlock()
                continuation?.resume()
            } else {
                lock.unlock()
            }

        case .fatal(let responseText):
            let error = IMAPClientError.connectionFailed(
                underlying: NSError(
                    domain: "com.ding.mac.imap",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Server closed connection: \(responseText.text)"]
                )
            )
            failAll(with: error)

        case .authenticationChallenge, .fetch, .idleStarted:
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

    func waitForResponse(tag: String) async throws -> TaggedResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<TaggedResponse, any Error>) in
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
                if let buffered = bufferedResponses.removeValue(forKey: tag) {
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
        bufferedResponses.removeValue(forKey: tag)
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }

    private func failAll(with error: any Error) {
        lock.lock()
        caughtError = error
        let greeting = greetingContinuation
        greetingContinuation = nil
        let commands = pendingCommands
        pendingCommands.removeAll()
        bufferedResponses.removeAll()
        lock.unlock()

        greeting?.resume(throwing: error)
        for (_, continuation) in commands {
            continuation.resume(throwing: error)
        }
    }
}
