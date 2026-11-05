import NIOCore
import NIOEmbedded
import NIOIMAPCore
import XCTest
@testable import ding

/// Exercises the real `IMAPResponseHandler` with scripted server responses over an `EmbeddedChannel`,
/// covering the routing and IDLE bookkeeping that `FakeIMAPClient` bypasses entirely.
final class IMAPResponseHandlerTests: XCTestCase {
    private var handler: IMAPResponseHandler!
    private var channel: EmbeddedChannel!

    override func setUp() async throws {
        handler = IMAPResponseHandler()
        channel = EmbeddedChannel(handler: handler)
        // The first untagged response from a server is its greeting.
        try channel.writeInbound(greeting())
        try await handler.waitForGreeting()
    }

    override func tearDown() async throws {
        _ = try? await channel.close().get()
    }

    // MARK: - Helpers

    private func greeting() -> Response {
        .untagged(.conditionalState(.ok(ResponseText(text: "IMAP ready"))))
    }

    private func exists(_ count: Int) -> Response {
        .untagged(.mailboxData(.exists(count)))
    }

    private func tagged(_ tag: String, text: String = "done") -> Response {
        .tagged(TaggedResponse(tag: tag, state: .ok(ResponseText(text: text))))
    }

    private func makeIdleStream() -> (AsyncThrowingStream<IdleEvent, any Error>, AsyncThrowingStream<IdleEvent, any Error>.Continuation) {
        var continuation: AsyncThrowingStream<IdleEvent, any Error>.Continuation!
        let stream = AsyncThrowingStream<IdleEvent, any Error> { continuation = $0 }
        return (stream, continuation)
    }

    // MARK: - Command routing

    func testTaggedResponseCarriesItsUntaggedPayloads() async throws {
        handler.beginCommand(tag: "d1")
        try channel.writeInbound(exists(7))
        try channel.writeInbound(tagged("d1"))

        let response = try await handler.waitForCommand(tag: "d1")
        XCTAssertEqual(response.untagged.count, 1)
        guard case .mailboxData(.exists(let count)) = response.untagged[0] else {
            return XCTFail("Expected the EXISTS payload to be attached to its command")
        }
        XCTAssertEqual(count, 7)
    }

    func testResponseArrivingBeforeWaiterIsBufferedNotLost() async throws {
        handler.beginCommand(tag: "d2")
        try channel.writeInbound(tagged("d2", text: "early"))

        let response = try await handler.waitForCommand(tag: "d2")
        XCTAssertEqual(response.tagged.tag, "d2")
    }

    func testCancelledCommandThrowsCancellation() async throws {
        handler.beginCommand(tag: "d3")
        let handler = self.handler!
        let waiter = Task { try await handler.waitForCommand(tag: "d3") }
        try await Task.sleep(nanoseconds: 50_000_000)
        waiter.cancel()

        do {
            _ = try await waiter.value
            XCTFail("A cancelled wait must not return a response")
        } catch is CancellationError {
            // expected
        }

        // A late reply for the cancelled command must be dropped without disturbing the next command.
        try channel.writeInbound(tagged("d3"))
        handler.beginCommand(tag: "d4")
        try channel.writeInbound(tagged("d4"))
        let next = try await handler.waitForCommand(tag: "d4")
        XCTAssertEqual(next.tagged.tag, "d4")
    }

    // MARK: - Failure propagation

    func testServerByeFailsPendingCommand() async throws {
        handler.beginCommand(tag: "d5")
        let handler = self.handler!
        let waiter = Task { try await handler.waitForCommand(tag: "d5") }
        try await Task.sleep(nanoseconds: 50_000_000)

        try channel.writeInbound(Response.fatal(ResponseText(text: "Server shutting down")))

        do {
            _ = try await waiter.value
            XCTFail("BYE must fail in-flight commands")
        } catch let error as IMAPClientError {
            guard case .connectionFailed = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testCommandAfterFailureFailsImmediately() async throws {
        try channel.writeInbound(Response.fatal(ResponseText(text: "bye")))
        handler.beginCommand(tag: "d6")
        do {
            _ = try await handler.waitForCommand(tag: "d6")
            XCTFail("A dead connection must not accept new waits")
        } catch {
            // expected
        }
    }

    // MARK: - IDLE bookkeeping

    func testExistsDuringIdleIsYielded() async throws {
        let (stream, continuation) = makeIdleStream()
        handler.setIdleContinuation(continuation)

        try channel.writeInbound(exists(9))

        var iterator = stream.makeAsyncIterator()
        let event = try await iterator.next()
        XCTAssertEqual(event, .newMailAvailable)
    }

    func testExistsAnnouncedBeforeIdleIsReplayedWhenIdleStarts() async throws {
        // Arrives while no IDLE stream is registered (e.g. during CAPABILITY or between fetch and IDLE).
        try channel.writeInbound(exists(12))

        let (stream, continuation) = makeIdleStream()
        handler.setIdleContinuation(continuation)

        var iterator = stream.makeAsyncIterator()
        let event = try await iterator.next()
        XCTAssertEqual(event, .newMailAvailable, "Mail announced before IDLE must not be dropped")
    }

    func testFetchClearsAnnouncedMailSoItIsNotReplayed() async throws {
        try channel.writeInbound(exists(12))
        handler.clearPendingExists() // a fetch begins and will pick the mail up

        let (stream, continuation) = makeIdleStream()
        handler.setIdleContinuation(continuation)
        handler.finishIdleContinuation()

        var iterator = stream.makeAsyncIterator()
        let event = try await iterator.next()
        XCTAssertNil(event, "No spurious event should be delivered after a fetch consumed the announcement")
    }

    func testFinishingIdleEndsTheConsumersStream() async throws {
        let (stream, continuation) = makeIdleStream()
        handler.setIdleContinuation(continuation)

        let consumer = Task { () -> Bool in
            do {
                for try await _ in stream {}
                return true
            } catch {
                return false
            }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        handler.finishIdleContinuation()

        let endedNormally = await consumer.value
        XCTAssertTrue(endedNormally, "Ending IDLE must wake a consumer suspended on the stream")
    }

    // MARK: - Cancellation before registration

    func testWaitEnteredAlreadyCancelledReturnsPromptly() async throws {
        handler.beginCommand(tag: "d7")
        let handler = self.handler!
        let task = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await handler.waitForCommand(tag: "d7")
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        let finished = LockProtected<Bool>(false)
        Task { _ = await task.value; finished.set(true) }
        for _ in 0..<50 {
            if finished.get() { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(finished.get(), "A wait entered by an already-cancelled task must not hang")
    }

    // MARK: - IDLE acknowledgement ordering

    func testIdleAcknowledgementArrivingBeforeWaiterIsNotLost() async throws {
        handler.prepareForIdleStart()
        try channel.writeInbound(Response.idleStarted)

        let handler = self.handler!
        let waiter = Task { () -> Bool in
            do { try await handler.waitForIdleStart(); return true } catch { return false }
        }
        let finished = LockProtected<Bool?>(nil)
        Task { finished.set(await waiter.value) }
        for _ in 0..<50 {
            if finished.get() != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(finished.get(), true, "An early IDLE acknowledgement must satisfy a later wait instead of timing out")
    }

    func testServerByeClosesTheChannel() throws {
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 993)).wait()
        XCTAssertTrue(channel.isActive)
        try channel.writeInbound(Response.fatal(ResponseText(text: "bye")))
        XCTAssertFalse(channel.isActive, "A channel that is failing every command must not keep reporting itself as connected")
    }

    func testFlagChangesAndRecentDoNotWakeIdle() async throws {
        let (stream, continuation) = makeIdleStream()
        handler.setIdleContinuation(continuation)

        // Reading a message on another device produces FETCH (flags); RECENT merely repeats an EXISTS.
        try channel.writeInbound(Response.fetch(.start(1)))
        try channel.writeInbound(Response.fetch(.finish))
        try channel.writeInbound(Response.untagged(.mailboxData(.recent(1))))
        handler.finishIdleContinuation()

        var iterator = stream.makeAsyncIterator()
        let event = try await iterator.next()
        XCTAssertNil(event, "Only EXISTS may trigger a fetch cycle")
    }
}
