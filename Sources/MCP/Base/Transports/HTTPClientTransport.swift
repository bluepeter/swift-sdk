import Foundation
import Logging

#if !os(Linux)
    import EventSource
#endif

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// MARK: - Timeout Helpers

/// Error thrown when an operation times out
/// An implementation of the MCP Streamable HTTP transport protocol for clients.
///
/// This transport implements the [Streamable HTTP transport](https://spec.modelcontextprotocol.io/specification/2025-11-25/basic/transports#streamable-http)
/// specification from the Model Context Protocol (version 2025-11-25).
///
/// It supports:
/// - Sending JSON-RPC messages via HTTP POST requests
/// - Receiving responses via both direct JSON responses and SSE streams
/// - Session management using the `MCP-Session-Id` header
/// - Protocol version negotiation via `MCP-Protocol-Version` header
/// - Automatic reconnection for dropped SSE streams with resumability support
/// - Platform-specific optimizations for different operating systems
///
/// The transport supports two modes:
/// - Regular HTTP (`streaming=false`): Simple request/response pattern
/// - Streaming HTTP with SSE (`streaming=true`): Enables server-to-client push messages
///
/// - Important: Server-Sent Events (SSE) functionality is not supported on Linux platforms.
///
/// ## Example Usage
///
/// ```swift
/// import MCP
///
/// // Create a streaming HTTP transport with bearer token authentication
/// let transport = HTTPClientTransport(
///     endpoint: URL(string: "https://api.example.com/mcp")!,
///     requestModifier: { request in
///         var modifiedRequest = request
///         modifiedRequest.addValue("Bearer your-token-here", forHTTPHeaderField: "Authorization")
///         return modifiedRequest
///     }
/// )
///
/// // Initialize the client with streaming transport
/// let client = Client(name: "MyApp", version: "1.0.0")
/// try await client.connect(transport: transport)
///
/// // The transport will automatically handle SSE events
/// // and deliver them through the client's notification handlers
/// ```
public actor HTTPClientTransport: Transport {
    /// The server endpoint URL to connect to
    public let endpoint: URL
    let session: URLSession

    /// The session ID assigned by the server, used for maintaining state across requests
    public internal(set) var sessionID: String?

    /// The negotiated protocol version to send in MCP-Protocol-Version header
    public var protocolVersion: String?

    let streaming: Bool
    var streamingTask: Task<Void, Never>?

    /// Logger instance for transport-related events
    public nonisolated let logger: Logger

    /// Maximum time to wait for a session ID before proceeding with SSE connection
    public let sseInitializationTimeout: TimeInterval

    /// Closure to modify requests before they are sent
    let requestModifier: (URLRequest) -> URLRequest

    /// Optional OAuth 2.1 authorizer.
    let authorizer: (any HTTPClientAuthorizer)?

    var isConnected = false
    private let messageStream: AsyncThrowingStream<Data, Swift.Error>
    let messageContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

    private var initialSessionIDSignalTask: Task<Void, Never>?
    private var initialSessionIDContinuation: CheckedContinuation<Void, Never>?

    /// The last event ID received from the server for SSE stream resumability
    private var lastEventID: String?

    /// The retry interval (in milliseconds) from the server's SSE `retry:` field
    private var retryInterval: Int = 3000  // Default 3000ms per SSE spec

    /// The underlying URLSession task for the active GET SSE stream.
    /// Used to trigger reconnection when a POST SSE stream closes without delivering data.
    var activeGETSessionTask: URLSessionDataTask?

    /// Creates a new HTTP transport client with the specified endpoint
    ///
    /// - Parameters:
    ///   - endpoint: The server URL to connect to
    ///   - configuration: URLSession configuration to use for HTTP requests
    ///   - streaming: Whether to enable SSE streaming mode (default: true)
    ///   - sseInitializationTimeout: Maximum time to wait for session ID before proceeding with SSE (default: 10 seconds)
    ///   - protocolVersion: The MCP protocol version to use (default: "2025-11-25")
    ///   - authorizer: Optional ``HTTPClientAuthorizer`` for automatic Bearer token acquisition and retries.
    ///   - requestModifier: Optional closure to customize requests before they are sent (default: no modification)
    ///   - logger: Optional logger instance for transport events
    public init(
        endpoint: URL,
        configuration: URLSessionConfiguration = .default,
        streaming: Bool = true,
        sseInitializationTimeout: TimeInterval = 10,
        protocolVersion: String = Version.latest,
        authorizer: (any HTTPClientAuthorizer)? = nil,
        requestModifier: @escaping (URLRequest) -> URLRequest = { $0 },
        logger: Logger? = nil
    ) {
        self.init(
            endpoint: endpoint,
            session: URLSession(configuration: configuration),
            streaming: streaming,
            sseInitializationTimeout: sseInitializationTimeout,
            protocolVersion: protocolVersion,
            authorizer: authorizer,
            requestModifier: requestModifier,
            logger: logger
        )
    }

    internal init(
        endpoint: URL,
        session: URLSession,
        streaming: Bool = false,
        sseInitializationTimeout: TimeInterval = 10,
        protocolVersion: String = Version.latest,
        authorizer: (any HTTPClientAuthorizer)? = nil,
        requestModifier: @escaping (URLRequest) -> URLRequest = { $0 },
        logger: Logger? = nil
    ) {
        self.endpoint = endpoint
        self.session = session
        self.streaming = streaming
        self.sseInitializationTimeout = sseInitializationTimeout
        self.protocolVersion = protocolVersion
        self.requestModifier = requestModifier
        self.authorizer = authorizer

        // Create message stream
        var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!
        self.messageStream = AsyncThrowingStream { continuation = $0 }
        self.messageContinuation = continuation

        self.logger =
            logger
            ?? Logger(
                label: "mcp.transport.http.client",
                factory: { _ in SwiftLogNoOpLogHandler() }
            )
    }

    // Setup the initial session ID signal
    private func setupInitialSessionIDSignal() {
        self.initialSessionIDSignalTask = Task {
            await withCheckedContinuation { continuation in
                self.initialSessionIDContinuation = continuation
            }
        }
    }

    // Trigger the initial session ID signal when a session ID is established
    func triggerInitialSessionIDSignal() {
        if let continuation = self.initialSessionIDContinuation {
            continuation.resume()
            self.initialSessionIDContinuation = nil
            logger.debug("✓ Initial session ID signal triggered for SSE task")
        } else {
            logger.debug("✗ No continuation to trigger - signal already consumed or SSE task not waiting")
        }
    }

    /// Establishes connection with the transport
    public func connect() async throws {
        guard !isConnected else { return }
        isConnected = true

        setupInitialSessionIDSignal()

        if streaming {
            streamingTask = Task { await startListeningForServerEvents() }
        }

        logger.debug("HTTP transport connected")
    }

    /// Disconnects from the transport
    public func disconnect() async {
        guard isConnected else { return }
        isConnected = false

        streamingTask?.cancel()
        streamingTask = nil

        session.invalidateAndCancel()
        messageContinuation.finish()

        initialSessionIDSignalTask?.cancel()
        initialSessionIDSignalTask = nil
        initialSessionIDContinuation?.resume()
        initialSessionIDContinuation = nil

        logger.debug("HTTP clienttransport disconnected")
    }

    /// Updates the protocol version used for `MCP-Protocol-Version` headers on subsequent requests.
    public func updateNegotiatedProtocolVersion(_ version: String) {
        self.protocolVersion = version
    }

    /// Receives data in an async sequence
    public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        return messageStream
    }

    // MARK: - SSE

    private func startListeningForServerEvents() async {
        #if os(Linux)
            if streaming {
                logger.warning(
                    "SSE streaming was requested but is not fully supported on Linux. SSE connection will not be attempted."
                )
            }
        #else
            guard isConnected else { return }

            if self.sessionID == nil, let signalTask = self.initialSessionIDSignalTask {
                logger.debug("⏳ Waiting for session ID to be set (timeout: \(self.sseInitializationTimeout)s)...")

                let startTime = Date()
                let timeout = self.sseInitializationTimeout
                do {
                    try await withThrowingTaskGroup { group in
                        group.addTask {
                            try await Task.sleep(for: .seconds(timeout))
                        }

                        group.addTask {
                            await signalTask.value
                        }

                        if let firstResult = try await group.next() {
                            group.cancelAll()
                            return firstResult
                        }
                    }
                } catch {
                    logger.warning("⏱️ Timeout waiting for session ID (\(timeout)s). SSE stream will proceed anyway.")
                }

                if self.sessionID != nil {
                    let elapsed = Date().timeIntervalSince(startTime)
                    logger.debug("✓ Session ID received after \(Int(elapsed * 1000))ms, proceeding with SSE connection")
                }
            } else {
                logger.debug("✓ Session ID already available, proceeding with SSE connection immediately")
            }

            var isFirstAttempt = true
            var attemptCount = 0

            logger.debug("🔄 Starting SSE retry loop", metadata: [
                "isConnected": "\(isConnected)",
                "isCancelled": "\(Task.isCancelled)"
            ])

            while isConnected && !Task.isCancelled {
                attemptCount += 1
                logger.debug("🔄 SSE retry loop iteration", metadata: [
                    "attempt": "\(attemptCount)",
                    "isFirstAttempt": "\(isFirstAttempt)"
                ])

                do {
                    if !isFirstAttempt {
                        let delayMs = self.retryInterval
                        logger.debug("⏳ Waiting before SSE reconnection", metadata: ["retryMs": "\(delayMs)"])
                        try await Task.sleep(for: .milliseconds(delayMs))
                        logger.debug("✓ Wait complete, reconnecting now")
                    }
                    isFirstAttempt = false

                    logger.debug("📡 Calling connectToEventStream (attempt #\(attemptCount))")

                    try await self.connectToEventStream()

                    logger.info("🔌 SSE stream closed gracefully, will reconnect", metadata: [
                        "attempt": "\(attemptCount)",
                        "willRetryAfter": "\(self.retryInterval)ms"
                    ])
                } catch {
                    if !Task.isCancelled {
                        logger.error("❌ SSE connection error (attempt #\(attemptCount)): \(error)")
                    } else {
                        logger.debug("⏹️ SSE task cancelled")
                    }
                }

                logger.debug("🔄 End of retry loop iteration", metadata: [
                    "isConnected": "\(isConnected)",
                    "isCancelled": "\(Task.isCancelled)",
                    "willContinue": "\(isConnected && !Task.isCancelled)"
                ])
            }

            logger.debug("⏹️ SSE retry loop exited", metadata: [
                "isConnected": "\(isConnected)",
                "isCancelled": "\(Task.isCancelled)",
                "totalAttempts": "\(attemptCount)"
            ])
        #endif
    }

    #if !os(Linux)
        private func connectToEventStream() async throws {
            var attempts = 0
            while true {
                guard isConnected else {
                    logger.debug("⚠️ Skipping connectToEventStream - transport not connected")
                    return
                }
                logger.debug("🔌 Preparing SSE connection request")
                var request = URLRequest(url: endpoint)
                request.httpMethod = "GET"
                request.addValue(ContentType.sse, forHTTPHeaderField: HTTPHeaderName.accept)
                request.addValue("no-cache", forHTTPHeaderField: HTTPHeaderName.cacheControl)
                if let protocolVersion {
                    request.addValue(protocolVersion, forHTTPHeaderField: HTTPHeaderName.protocolVersion)
                }
                if let sessionID {
                    request.addValue(sessionID, forHTTPHeaderField: HTTPHeaderName.sessionID)
                }
                if let lastEventID {
                    request.addValue(lastEventID, forHTTPHeaderField: HTTPHeaderName.lastEventID)
                    logger.info("→ Resuming SSE stream with Last-Event-ID", metadata: ["lastEventID": "\(lastEventID)"])
                } else {
                    logger.info("→ Connecting to SSE stream (no last event ID to resume from)")
                }
                request = try await authorizedRequest(request)
                do {
                    try await receiveEventStream(request)
                    return
                } catch let error as HTTPAuthenticationChallengeError {
                    try await handleAuthorizationChallenge(error, operationKey: nil, attempts: attempts)
                    attempts += 1
                }
            }
        }

        private func receiveEventStream(_ request: URLRequest) async throws {
            logger.debug("Starting SSE connection")
            let (stream, response) = try await session.bytes(for: request)
            activeGETSessionTask = stream.task
            // A rejected response can keep its body open. Close every attempt,
            // including authorization challenges, before starting its retry.
            defer {
                stream.task.cancel()
                activeGETSessionTask = nil
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                throw MCPError.internalError("Invalid HTTP response")
            }
            if let challenge = authorizationChallenge(for: httpResponse) { throw challenge }
            guard httpResponse.statusCode == 200 else {
                if httpResponse.statusCode == 405 {
                    streamingTask?.cancel()
                }
                throw MCPError.internalError("HTTP error: \(httpResponse.statusCode)")
            }
            if let newSessionID = httpResponse.value(forHTTPHeaderField: HTTPHeaderName.sessionID) {
                let wasSessionIDNil = (self.sessionID == nil)
                self.sessionID = newSessionID
                if wasSessionIDNil {
                    triggerInitialSessionIDSignal()
                }
                logger.debug("Session ID received", metadata: ["sessionID": "\(newSessionID)"])
            }
            try await processSSE(stream)
        }

        @discardableResult
        func processSSE(_ stream: URLSession.AsyncBytes) async throws -> Bool {
            logger.debug("📥 Starting SSE event processing")
            var eventCount = 0
            var hadDataEvent = false

            for try await event in stream.events {
                eventCount += 1

                if Task.isCancelled {
                    logger.debug("⏹️ SSE processing cancelled", metadata: ["eventsProcessed": "\(eventCount)"])
                    break
                }

                logger.trace(
                    "SSE event received",
                    metadata: [
                        "type": "\(event.event ?? "message")",
                        "id": "\(event.id ?? "none")",
                    ]
                )

                if let eventID = event.id, !eventID.isEmpty {
                    self.lastEventID = eventID
                    logger.debug("Stored event ID for resumability", metadata: ["eventID": "\(eventID)"])
                }

                if let retry = event.retry {
                    self.retryInterval = retry
                    logger.debug("SSE retry interval updated", metadata: ["retryMs": "\(retry)"])
                }

                if !event.data.isEmpty, let data = event.data.data(using: .utf8) {
                    hadDataEvent = true
                    messageContinuation.yield(data)
                }
            }

            logger.debug("✓ SSE event stream completed", metadata: ["eventsProcessed": "\(eventCount)", "hadData": "\(hadDataEvent)"])
            return hadDataEvent
        }
    #endif
}
