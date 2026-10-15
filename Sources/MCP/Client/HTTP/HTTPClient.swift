#if canImport(EventSource)
    import Foundation

    /// HTTP client supporting 2026 discovery/MRTR and the existing SDK's legacy tool path.
    /// The legacy Client and HTTPClientTransport retain their behavior and public APIs.
    public actor HTTPClient {
        /// The protocol revision implemented by this client's form input/retry flow.
        public static let formElicitationProtocolVersion = HTTPProtocol.version
        private let info: Client.Info
        private let supportsForms: Bool
        private let maximumInputRounds: Int
        private var legacy: Client?
        private var ownedSession: URLSession?
        private var modern: ModernHTTPConnection?
        private var supportsTasks = false
        private var generation = UUID()
        private var operations: [ID: @Sendable () -> Void] = [:]
        private var handlers: [String: [@Sendable (Value) async throws -> Void]] = [:]
        private var registrations: [@Sendable (Client) async -> Void] = []
        private var toolSchemas: [String: Value] = [:]
        private var subscription: HTTPToolSubscription?
        private var subscriptionRestoredHandlers: [@Sendable () async -> Void] = []

        /// A finite round limit also bounds state-only retries that never ask the user anything.
        public init(name: String, version: String, supportsForms: Bool = false, maximumInputRounds: Int = 16) {
            precondition(maximumInputRounds > 0)
            info = Client.Info(name: name, version: version)
            self.supportsForms = supportsForms
            self.maximumInputRounds = maximumInputRounds
        }

        @discardableResult
        public func onNotification<N: Notification>(
            _ type: N.Type, handler: @escaping @Sendable (Message<N>) async throws -> Void
        ) async -> Self {
            handlers[N.name, default: []].append { value in
                try await handler(JSONDecoder().decode(Message<N>.self, from: JSONEncoder().encode(value)))
            }
            registrations.append { client in await client.onNotification(type, handler: handler) }
            if let legacy {
                await legacy.onNotification(type, handler: handler)
            }
            return self
        }

        /// Called after a replacement tool notification stream is acknowledged.
        /// Refresh cached tools here: changes during the outage cannot be replayed.
        @discardableResult
        public func onToolSubscriptionRestored(_ handler: @escaping @Sendable () async -> Void) -> Self {
            subscriptionRestoredHandlers.append(handler)
            return self
        }

        /// Rearm an exhausted recovery cycle on foreground or explicit tool use.
        /// Coalesces with an active stream/retry and never sends tool requests.
        public func recoverToolSubscription() async {
            await subscription?.resume()
        }

        public func connect(
            endpoint: URL, session: URLSession? = nil,
            requestModifier: @escaping @Sendable (URLRequest) -> URLRequest = { $0 }
        ) async throws -> HTTPConnectionInfo {
            await disconnect()
            let attempt = generation
            let session = session ?? makeSession()
            let connection = ModernHTTPConnection(
                endpoint: endpoint,
                session: session,
                clientInfo: info,
                requestModifier: requestModifier,
                maximumMessageBytes: 16 * 1024 * 1024
            )
            modern = connection
            do {
                let context: RequestContext<HTTPDiscovery> = start(id: .random) {
                    try await connection.request(
                        method: "server/discover",
                        id: .random,
                        parameters: [:],
                        formSupport: self.supportsForms,
                        notification: { _ in }
                    )
                }
                let result = try await awaitCancellable(context)
                try check(attempt)
                guard result.supportedVersions.contains(HTTPProtocol.version)
                else { throw HTTPClientError.unsupportedVersion }
                supportsTasks = result.supportsTasks
                let receivesChanges = result.capabilities.tools != nil ? await startToolSubscription(connection) : false
                try check(attempt)
                return HTTPConnectionInfo(
                    protocolVersion: HTTPProtocol.version,
                    capabilities: result.capabilities,
                    instructions: result.instructions,
                    subscribedToToolChanges: receivesChanges,
                    supportsTasks: result.supportsTasks
                )
            } catch {
                try check(attempt)
                guard Self.isLegacyProbeResponse(error) else { modern = nil
                    throw error
                }
                modern = nil
                let transport = HTTPClientTransport(
                    endpoint: endpoint,
                    session: session,
                    streaming: true,
                    requestModifier: requestModifier
                )
                return try await connectLegacy(transport: transport, attempt: attempt)
            }
        }

        private func makeSession() -> URLSession {
            let session = URLSession(configuration: .default)
            ownedSession = session
            return session
        }

        /// Existing SDK transports remain useful for legacy servers and deterministic integration tests.
        public func connect(transport: any Transport) async throws -> HTTPConnectionInfo {
            await disconnect()
            return try await connectLegacy(transport: transport, attempt: generation)
        }

        private func connectLegacy(transport: any Transport, attempt: UUID) async throws -> HTTPConnectionInfo {
            let client = Client(name: info.name, version: info.version)
            // Explain a known unsupported flow without advertising it or waiting for input.
            await client.withMethodHandler(CreateElicitation.self) { _ in
                throw MCPError.methodNotFound(
                    "Elicitation callbacks are not supported on this connection. "
                        + "Form elicitation requires MCP \(HTTPProtocol.version) input_required responses "
                        + "and inputResponses on the retried request. URL elicitation is not supported."
                )
            }
            legacy = client
            for register in registrations {
                await register(client)
            }
            do {
                let result = try await withTaskCancellationHandler {
                    try await client.connect(transport: transport)
                } onCancel: { Task { await client.disconnect() } }
                try check(attempt)
                return HTTPConnectionInfo(
                    protocolVersion: result.protocolVersion,
                    capabilities: result.capabilities,
                    instructions: result.instructions
                )
            } catch {
                await client.disconnect()
                if generation == attempt {
                    legacy = nil
                }
                throw error
            }
        }

        public func send<M: Method>(_ request: Request<M>) async throws -> RequestContext<M.Result> {
            if let legacy {
                return try await legacy.send(request)
            }
            guard let modern else { throw MCPError.internalError("Client is not connected") }
            let attempt = generation
            return start(id: request.id) { [supportsForms] in
                let result: M.Result = try await modern.request(
                    method: M.name, id: request.id, parameters: HTTPProtocol.parameters(request.params),
                    formSupport: supportsForms, notification: { try await self.receive($0) }
                )
                try await self.check(attempt)
                if let page = result as? ListTools.Result {
                    let filtered = ListTools.Result(tools: page.tools.filter { tool in
                        do { try HTTPRoutingHeaders.validate(tool.inputSchema)
                            return true
                        } catch { return false }
                    }, nextCursor: page.nextCursor, _meta: page._meta)
                    await self.remember(filtered.tools)
                    guard let typed = filtered as? M.Result else { throw HTTPClientError.invalidResponse }
                    return typed
                }
                return result
            }
        }

        /// One cancellable operation owns every round and every form wait.
        public func callTool(
            name: String, arguments: [String: Value]? = nil, meta: Metadata? = nil, inputSchema: Value? = nil,
            formHandler: HTTPFormHandler? = nil, taskHandler: HTTPTaskHandler? = nil
        ) async throws -> RequestContext<CallTool.Result> {
            if let legacy {
                return try await legacy.callTool(name: name, arguments: arguments, meta: meta)
            }
            guard let modern else { throw MCPError.internalError("Client is not connected") }
            let schema = inputSchema ?? toolSchemas[name]
            let rounds = maximumInputRounds
            let taskSupport = supportsTasks && taskHandler != nil
            return start(id: .random) {
                var parameters = try HTTPProtocol.parameters(CallTool.Parameters(
                    name: name,
                    arguments: arguments,
                    meta: meta
                ))
                for _ in 0 ..< rounds {
                    try Task.checkCancellation()
                    let result: HTTPToolResult = try await modern.request(
                        method: CallTool.name, id: .random, parameters: parameters, schema: schema,
                        formSupport: formHandler != nil, taskSupport: taskSupport, notification: { try await self.receive($0) }
                    )
                    switch result {
                    case let .complete(result): return result
                    case let .task(task):
                        guard taskSupport, let taskHandler else { throw HTTPClientError.invalidResponse }
                        return try await taskHandler(task)
                    case let .inputRequired(input):
                        guard input.inputRequests != nil || input.requestState != nil
                        else { throw HTTPClientError.invalidResponse }
                        let responses = try await input.responses(using: formHandler)
                        parameters["inputResponses"] = input.inputRequests == nil ? nil : .object(responses)
                        parameters["requestState"] = input.requestState.map(Value.string)
                    }
                }
                throw HTTPClientError.inputRoundLimit
            }
        }

        /// Task lifecycle calls never replay the tool that created the task.
        public func getTask(_ taskID: String) async throws -> HTTPTaskState {
            try await taskRequest("tasks/get", parameters: ["taskId": .string(taskID)])
        }

        public func updateTask(_ taskID: String, responses: [String: Value]) async throws {
            let _: Empty = try await taskRequest("tasks/update", parameters: [
                "taskId": .string(taskID), "inputResponses": .object(responses)
            ])
        }

        /// Acknowledges intent only. Query the task to determine its final status.
        public func cancelTask(_ taskID: String) async throws {
            let _: Empty = try await taskRequest("tasks/cancel", parameters: ["taskId": .string(taskID)])
        }

        private func taskRequest<Output: Decodable & Sendable>(
            _ method: String, parameters: [String: Value]
        ) async throws -> Output {
            guard let modern, supportsTasks else { throw HTTPClientError.unsupportedVersion }
            let attempt = generation
            let context: RequestContext<Output> = start(id: .random) {
                let result: Output = try await modern.request(
                    method: method, id: .random, parameters: parameters,
                    formSupport: self.supportsForms, taskSupport: true,
                    notification: { try await self.receive($0) }
                )
                try await self.check(attempt)
                return result
            }
            return try await awaitCancellable(context)
        }

        public func cancelRequest(_ id: ID, reason: String? = nil) async throws {
            if let legacy {
                try await legacy.cancelRequest(id, reason: reason)
            }
            operations.removeValue(forKey: id)?()
        }

        public func disconnect() async {
            generation = UUID()
            let previousSubscription = subscription
            subscription = nil
            let pending = operations.values
            operations.removeAll()
            for cancel in pending {
                cancel()
            }
            modern = nil
            supportsTasks = false
            ownedSession?.invalidateAndCancel()
            ownedSession = nil
            toolSchemas.removeAll()
            let old = legacy
            legacy = nil
            await previousSubscription?.stop()
            await old?.disconnect()
        }

        private func start<Output: Decodable & Sendable>(
            id: ID, operation: @escaping @Sendable () async throws -> Output
        ) -> RequestContext<Output> {
            let task = Task {
                defer { operations[id] = nil }
                try Task.checkCancellation()
                do {
                    let result = try await operation()
                    try Task.checkCancellation()
                    return result
                } catch {
                    try Task.checkCancellation()
                    throw error
                }
            }
            operations[id] = { task.cancel() }
            return RequestContext(requestID: id, requestTask: task)
        }

        private func awaitCancellable<Output>(_ context: RequestContext<Output>) async throws -> Output {
            try await withTaskCancellationHandler {
                let result = try await context.value
                try Task.checkCancellation()
                return result
            } onCancel: { Task { try? await self.cancelRequest(context.requestID) } }
        }

        private func check(_ attempt: UUID) throws {
            try Task.checkCancellation()
            guard attempt == generation else { throw CancellationError() }
        }

        private func remember(_ tools: [Tool]) {
            for tool in tools {
                toolSchemas[tool.name] = tool.inputSchema
            }
        }

        private func receive(_ message: Value) async throws {
            guard let method = message[httpField: "method"]?.stringValue else { throw HTTPClientError.invalidResponse }
            for handler in handlers[method] ?? [] {
                try await handler(message)
            }
        }

        private static func isLegacyProbeResponse(_ error: Error) -> Bool {
            guard case let HTTPClientError.response(status, code, _, data) = error else { return false }
            // Authentication, rate limits, outages, and recognized modern errors are never
            // downgraded. Only the side-effect-free discovery probe may select the legacy path.
            guard status == 400 || status == 404 || (200 ..< 300).contains(status) else { return false }
            if code == -32022 {
                let supported = data?[httpField: "supported"]?.arrayValue?.compactMap(\.stringValue) ?? []
                return !Set(supported).intersection(Version.supported).isEmpty
            }
            if let code, [-32020, -32021].contains(code) {
                return false
            }
            return status == 400 || (status == 404 && code == nil)
                || ((200 ..< 300).contains(status) && code == -32601)
        }

        private func startToolSubscription(_ connection: ModernHTTPConnection) async -> Bool {
            guard handlers[ToolListChangedNotification.name] != nil else { return false }
            let attempt = generation
            let subscription = HTTPToolSubscription(
                connection: connection, supportsForms: supportsForms,
                notification: { [weak self] message in
                    guard let self else { return }
                    try await check(attempt)
                    try await receive(message)
                },
                restored: { [weak self] in await self?.toolSubscriptionRestored(attempt) }
            )
            self.subscription = subscription
            return await subscription.start()
        }

        private func toolSubscriptionRestored(_ attempt: UUID) async {
            for handler in subscriptionRestoredHandlers {
                guard attempt == generation, !Task.isCancelled else { return }
                await handler()
            }
        }
    }
#endif
