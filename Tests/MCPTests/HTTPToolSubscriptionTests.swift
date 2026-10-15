#if canImport(EventSource)
    import Foundation
    @testable import MCP
    import Testing

    @Suite("Tool subscription recovery", .timeLimit(.minutes(1)))
    struct HTTPToolSubscriptionTests {
        @Test("Drops and graceful closure recover once; disconnect is terminal", arguments: [false, true])
        func recovery(graceful: Bool) async throws {
            let server = SubscriptionServer()
            let fixture = HTTPClientFixture { _, body in try await server.reply(body) }
            let backoff = SubscriptionBackoff()
            let (restored, restoredSignal) = AsyncStream<Void>.makeStream()
            let subscription = makeSubscription(fixture, restored: { restoredSignal.yield(()) }, sleep: backoff.sleep)
            #expect(await subscription.start())
            var connections = server.connections.makeAsyncIterator()
            let first = try #require(await connections.next())
            if graceful {
                try first.send(httpResult(first.request, [
                    "resultType": "complete",
                    "_meta": [HTTPProtocol.subscriptionKey: first.id]
                ]))
            }
            first.body.finish()
            var delays = backoff.delays.makeAsyncIterator()
            #expect(await delays.next() == HTTPToolSubscription.retryDelays.first)
            for _ in 0 ..< 100 {
                await subscription.resume()
            }
            #expect(await server.count == 1)
            await backoff.advance()
            let second = try #require(await connections.next())
            var acknowledgments = restored.makeAsyncIterator()
            _ = try #require(await acknowledgments.next())
            #expect(second.id != first.id)
            #expect(await server.count == 2)
            let running = await subscription.task
            await subscription.stop()
            await running?.value
            await subscription.resume()
            #expect(await subscription.task == nil)
            #expect(await server.count == 2)
        }

        @Test("An acknowledged stream that immediately closes cannot retry indefinitely")
        func boundedRecovery() async {
            let ledger = HTTPRequestLedger()
            let fixture = HTTPClientFixture { _, body in
                await ledger.append(body)
                return try subscriptionReply(body)
            }
            let subscription = makeSubscription(fixture, sleep: { _ in try Task.checkCancellation() })
            #expect(await subscription.start())
            await subscription.task?.value
            #expect(await ledger.requests.count == 1 + HTTPToolSubscription.retryDelays.count)
            await subscription.resume()
            await subscription.task?.value
            #expect(await ledger.requests.count == 2 * (1 + HTTPToolSubscription.retryDelays.count))
            await subscription.stop()
        }

        @Test("Stopping during backoff prevents another HTTP request")
        func stopBackoff() async throws {
            let ledger = HTTPRequestLedger()
            let fixture = HTTPClientFixture { _, body in
                await ledger.append(body)
                return try subscriptionReply(body)
            }
            let backoff = SubscriptionBackoff()
            let subscription = makeSubscription(fixture, sleep: backoff.sleep)
            #expect(await subscription.start())
            var delays = backoff.delays.makeAsyncIterator()
            _ = try #require(await delays.next())
            let running = await subscription.task
            await subscription.stop()
            await backoff.advance()
            await running?.value
            await subscription.resume()
            #expect(await ledger.requests.count == 1)
        }

        @Test("A stable acknowledged connection earns a fresh automatic retry budget")
        func stableConnection() async {
            let ledger = HTTPRequestLedger()
            let clock = SubscriptionClock()
            let fixture = HTTPClientFixture { _, body in
                await ledger.append(body)
                var reply = try subscriptionReply(body)
                reply = try .init(headers: reply.headers, body: reply.body + subscriptionFrame([
                    "jsonrpc": "2.0", "method": "notifications/tools/list_changed",
                    "params": ["_meta": [HTTPProtocol.subscriptionKey: body[httpField: "id"] ?? .null]]
                ]))
                return reply
            }
            let subscription = makeSubscription(fixture, notification: { _ in
                if await ledger.requests.count == 1 + HTTPToolSubscription.retryDelays.count {
                    clock.advance(by: HTTPToolSubscription.stableInterval)
                }
            }, sleep: { _ in try Task.checkCancellation() }, now: clock.now)
            #expect(await subscription.start())
            await subscription.task?.value
            #expect(await ledger.requests.count == 1 + 2 * HTTPToolSubscription.retryDelays.count)
            await subscription.stop()
        }

        @Test("Rejected filters and permanent HTTP errors do not retry", arguments: [200, 401, 403, 404])
        func unsupported(status: Int) async {
            let ledger = HTTPRequestLedger()
            let fixture = HTTPClientFixture { _, body in
                await ledger.append(body)
                if status == 200 {
                    return try subscriptionReply(body, enabled: false)
                }
                return .init(status: status, body: Data())
            }
            let subscription = makeSubscription(fixture, sleep: { _ in Issue.record("Permanent refusal retried") })
            #expect(await subscription.start() == false)
            await subscription.task?.value
            await subscription.resume()
            #expect(await subscription.task == nil)
            #expect(await ledger.requests.count == 1)
            await subscription.stop()
        }

        @Test("An initial listen failure recovers through the public client callback")
        func initialFailure() async throws {
            let server = SubscriptionServer()
            let ledger = HTTPRequestLedger()
            let fixture = HTTPClientFixture { _, body in
                if body[httpField: "method"] == "server/discover" {
                    return try .json(httpResult(body, httpDiscovery))
                }
                await ledger.append(body)
                if await ledger.requests.count == 1 {
                    return .init(status: 503, body: Data())
                }
                return try await server.reply(body)
            }
            let client = HTTPClient(name: "tests", version: "1")
            await client.onNotification(ToolListChangedNotification.self) { _ in }
            let (restored, signal) = AsyncStream<Void>.makeStream()
            await client.onToolSubscriptionRestored { signal.yield(()) }
            let info = try await client.connect(endpoint: fixture.endpoint, session: fixture.session)
            #expect(!info.supportsToolListChanges)
            var acknowledgments = restored.makeAsyncIterator()
            _ = try #require(await acknowledgments.next())
            for _ in 0 ..< 100 {
                await client.recoverToolSubscription()
            }
            #expect(await ledger.requests.count == 2)
            await client.disconnect()
            await client.recoverToolSubscription()
            #expect(await ledger.requests.count == 2)
        }

        private func makeSubscription(
            _ fixture: HTTPClientFixture,
            notification: @escaping @Sendable (Value) async throws -> Void = { _ in },
            restored: @escaping @Sendable () async -> Void = {},
            sleep: @escaping @Sendable (Duration) async throws -> Void,
            now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
        ) -> HTTPToolSubscription {
            HTTPToolSubscription(connection: .init(
                endpoint: fixture.endpoint, session: fixture.session,
                clientInfo: .init(name: "test", version: "1"), requestModifier: { $0 },
                maximumMessageBytes: 16 * 1024 * 1024
            ), supportsForms: false, notification: notification, restored: restored, sleep: sleep, now: now)
        }
    }

    private func subscriptionReply(_ request: Value, enabled: Bool = true) throws -> HTTPClientFixture.Reply {
        let ack: Value = [
            "jsonrpc": "2.0", "method": "notifications/subscriptions/acknowledged",
            "params": [
                "_meta": [HTTPProtocol.subscriptionKey: request[httpField: "id"] ?? .null],
                "notifications": ["toolsListChanged": .bool(enabled)]
            ]
        ]
        return try .init(headers: ["Content-Type": "text/event-stream"], body: subscriptionFrame(ack))
    }

    private func subscriptionFrame(_ message: Value) throws -> Data {
        try Data("data: \(String(decoding: JSONEncoder().encode(message), as: UTF8.self))\n\n".utf8)
    }

    private actor SubscriptionServer {
        struct Connection: Sendable {
            let request: Value
            let body: AsyncThrowingStream<Data, Error>.Continuation
            var id: Value {
                request[httpField: "id"] ?? .null
            }

            func send(_ value: Value) throws {
                try body.yield(subscriptionFrame(value))
            }
        }

        nonisolated let connections: AsyncStream<Connection>
        private let connected: AsyncStream<Connection>.Continuation
        private(set) var count = 0

        init() {
            (connections, connected) = AsyncStream<Connection>.makeStream()
        }

        func reply(_ request: Value) throws -> HTTPClientFixture.Reply {
            count += 1
            let (body, signal) = AsyncThrowingStream<Data, Error>.makeStream()
            connected.yield(.init(request: request, body: signal))
            var reply = try subscriptionReply(request)
            reply.additionalBody = body
            return reply
        }
    }

    private actor SubscriptionBackoff {
        nonisolated let delays: AsyncStream<Duration>
        private let delayed: AsyncStream<Duration>.Continuation
        private var pending: AsyncStream<Void>.Continuation?

        init() {
            (delays, delayed) = AsyncStream<Duration>.makeStream()
        }

        func sleep(_ duration: Duration) async throws {
            let (gate, signal) = AsyncStream<Void>.makeStream()
            pending = signal
            delayed.yield(duration)
            for await _ in gate {
                break
            }
            try Task.checkCancellation()
        }

        func advance() {
            pending?.finish()
            pending = nil
        }
    }

    private final class SubscriptionClock: @unchecked Sendable {
        private let lock = NSLock()
        private var instant = ContinuousClock.now
        func now() -> ContinuousClock.Instant {
            lock.withLock { instant }
        }

        func advance(by duration: Duration) {
            lock.withLock { instant += duration }
        }
    }
#endif
