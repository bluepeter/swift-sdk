#if canImport(EventSource)
    import Foundation
    import Logging

    /// Owns exactly one listen request or backoff task. Ordinary requests are
    /// independent, and explicit stop is terminal for this connection owner.
    actor HTTPToolSubscription {
        // Three replacements per outage. A stream that stays acknowledged for
        // 30 seconds earns a fresh budget; ack/close loops cannot retry forever.
        static let retryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4)]
        static let stableInterval: Duration = .seconds(30)

        private let connection: ModernHTTPConnection
        private let supportsForms: Bool
        private let notification: @Sendable (Value) async throws -> Void
        private let restored: @Sendable () async -> Void
        private let sleep: @Sendable (Duration) async throws -> Void
        private let now: @Sendable () -> ContinuousClock.Instant
        private let logger = Logger(label: "mcp.http-client")
        private(set) var task: Task<Void, Never>?
        private var stopped = false
        private var hasAttempted = false
        private var activeID: ID?
        private var acknowledgedAt: ContinuousClock.Instant?

        init(
            connection: ModernHTTPConnection, supportsForms: Bool,
            notification: @escaping @Sendable (Value) async throws -> Void,
            restored: @escaping @Sendable () async -> Void,
            sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
            now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
        ) {
            self.connection = connection
            self.supportsForms = supportsForms
            self.notification = notification
            self.restored = restored
            self.sleep = sleep
            self.now = now
        }

        func start() async -> Bool {
            let (ready, signal) = AsyncStream<Bool>.makeStream()
            launch(ready: signal)
            return await withTaskCancellationHandler {
                for await enabled in ready {
                    return enabled
                }
                return false
            } onCancel: { Task { await self.stop() } }
        }

        func resume() {
            launch(ready: nil)
        }

        func stop() {
            stopped = true
            activeID = nil
            task?.cancel()
            task = nil
        }

        private func launch(ready: AsyncStream<Bool>.Continuation?) {
            guard !stopped, task == nil else { ready?.finish()
                return
            }
            task = Task { await run(ready: ready) }
        }

        private func run(ready: AsyncStream<Bool>.Continuation?) async {
            defer { task = nil
                activeID = nil
                ready?.finish()
            }
            var retries = 0
            var delay: Duration?
            while !stopped, !Task.isCancelled {
                do {
                    if let delay {
                        try await sleep(delay)
                    }
                    try Task.checkCancellation()
                    guard !stopped else { break }
                    let id = ID.random
                    let replacement = hasAttempted
                    hasAttempted = true
                    activeID = id
                    acknowledgedAt = nil
                    let result: Value = try await connection.request(
                        method: "subscriptions/listen", id: id,
                        parameters: ["notifications": ["toolsListChanged": true]],
                        formSupport: supportsForms,
                        notification: { message in
                            try await self.receive(message, id: id, replacement: replacement, ready: ready)
                        }
                    )
                    guard acknowledgedAt != nil,
                          try result[httpField: "_meta"]?[httpField: HTTPProtocol.subscriptionKey] == HTTPProtocol
                          .value(id)
                    else { throw HTTPClientError.invalidResponse }
                } catch {
                    if stopped || Task.isCancelled {
                        break
                    }
                    if Self.isPermanent(error) {
                        logger.warning("MCP tool list subscription rejected; reconnect after configuration changes")
                        stopped = true
                    }
                }
                ready?.yield(false)
                ready?.finish()
                guard !stopped, !Task.isCancelled else { break }
                logger.warning("MCP tool list subscription ended")
                if let acknowledgedAt, now() - acknowledgedAt >= Self.stableInterval {
                    retries = 0
                }
                guard retries < Self.retryDelays.count else {
                    logger.warning("MCP tool list subscription recovery exhausted; waiting for host activity")
                    break
                }
                delay = Self.retryDelays[retries]
                retries += 1
            }
        }

        private func receive(
            _ message: Value, id: ID, replacement: Bool, ready: AsyncStream<Bool>.Continuation?
        ) async throws {
            try Task.checkCancellation()
            guard !stopped, activeID == id else { throw CancellationError() }
            guard try message[httpField: "params"]?[httpField: "_meta"]?[httpField: HTTPProtocol.subscriptionKey] ==
                HTTPProtocol.value(id)
            else { throw HTTPClientError.invalidResponse }
            if message[httpField: "method"] == "notifications/subscriptions/acknowledged" {
                guard acknowledgedAt == nil else { throw HTTPClientError.invalidResponse }
                guard message[httpField: "params"]?[httpField: "notifications"]?[httpField: "toolsListChanged"] == true
                else {
                    stopped = true
                    ready?.yield(false)
                    ready?.finish()
                    throw CancellationError()
                }
                acknowledgedAt = now()
                ready?.yield(true)
                ready?.finish()
                if replacement {
                    await restored()
                }
            } else {
                guard acknowledgedAt != nil else { throw HTTPClientError.invalidResponse }
                if message[httpField: "method"] == .string(ToolListChangedNotification.name) {
                    try await notification(message)
                }
            }
        }

        private static func isPermanent(_ error: Error) -> Bool {
            guard case let HTTPClientError.response(status, code, _, _) = error else { return false }
            if let code, [-32601, -32602, -32020, -32021, -32022].contains(code) {
                return true
            }
            return (400 ..< 500).contains(status) && status != 408 && status != 429
        }
    }
#endif
