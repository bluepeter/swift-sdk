#if canImport(EventSource)
    import EventSource
    import Foundation

    /// One URLSession task per protocol request. Cancelling it closes only that request's stream.
    struct HTTPResponseStream: Sendable {
        enum Event: Sendable {
            case response(HTTPURLResponse)
            case data(Data)
        }

        let task: URLSessionDataTask
        let events: AsyncThrowingStream<Event, Error>
        let consumed: @Sendable (Int) -> Void

        init(request: URLRequest, session: URLSession, maximumBufferedBytes: Int) {
            let (events, continuation) = AsyncThrowingStream<Event, Error>.makeStream()
            let delegate = Delegate(continuation: continuation, maximumBufferedBytes: maximumBufferedBytes)
            let task = session.dataTask(with: request)
            task.delegate = delegate
            continuation.onTermination = { @Sendable _ in task.cancel() }
            self.task = task
            self.events = events
            consumed = { delegate.consumed($0) }
        }

        private final class Delegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
            let continuation: AsyncThrowingStream<Event, Error>.Continuation
            let maximumBufferedBytes: Int
            // URLSession produces chunks independently of the async consumer. Bound that queue
            // as well as individual parsed messages; all byte accounting is protected by this lock.
            private let lock = NSLock()
            private var bufferedBytes = 0

            init(continuation: AsyncThrowingStream<Event, Error>.Continuation, maximumBufferedBytes: Int) {
                self.continuation = continuation
                self.maximumBufferedBytes = maximumBufferedBytes
            }

            func consumed(_ count: Int) {
                lock.withLock { bufferedBytes -= count }
            }

            func urlSession(
                _: URLSession,
                dataTask _: URLSessionDataTask,
                didReceive response: URLResponse,
                completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
            ) {
                guard let response = response as? HTTPURLResponse else {
                    continuation.finish(throwing: HTTPClientError.invalidResponse)
                    completionHandler(.cancel)
                    return
                }
                continuation.yield(.response(response))
                completionHandler(.allow)
            }

            func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
                let fits = lock.withLock {
                    guard data.count <= maximumBufferedBytes - bufferedBytes else { return false }
                    bufferedBytes += data.count
                    return true
                }
                guard fits else {
                    continuation.finish(throwing: HTTPClientError.messageTooLarge)
                    dataTask.cancel()
                    return
                }
                continuation.yield(.data(data))
            }

            func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
                continuation.finish(throwing: error)
            }

            /// Do not forward custom credentials or replay a tool POST to a redirected endpoint.
            func urlSession(
                _: URLSession,
                task _: URLSessionTask,
                willPerformHTTPRedirection _: HTTPURLResponse,
                newRequest _: URLRequest,
                completionHandler: @escaping @Sendable (URLRequest?) -> Void
            ) {
                completionHandler(nil)
            }
        }
    }

    struct ModernHTTPConnection: Sendable {
        let endpoint: URL
        let session: URLSession
        let clientInfo: Client.Info
        let requestModifier: @Sendable (URLRequest) -> URLRequest
        /// Bounds an individual result/event, not the lifetime of a notification stream.
        let maximumMessageBytes: Int

        func request<Output: Decodable & Sendable>(
            method: String, id: ID, parameters: [String: Value], schema: Value? = nil,
            formSupport: Bool,
            notification: @escaping @Sendable (Value) async throws -> Void
        ) async throws -> Output {
            var parameters = parameters
            var metadata = parameters["_meta"]?.objectValue ?? [:]
            metadata[HTTPProtocol.versionKey] = .string(HTTPProtocol.version)
            metadata[HTTPProtocol.clientInfoKey] = try HTTPProtocol.value(clientInfo)
            metadata[HTTPProtocol.capabilitiesKey] = formSupport ? ["elicitation": ["form": [:]]] : [:]
            parameters["_meta"] = .object(metadata)
            let body: Value = try [
                "jsonrpc": "2.0",
                "id": HTTPProtocol.value(id),
                "method": .string(method),
                "params": .object(parameters)
            ]
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request = requestModifier(request)
            // Protocol-owned headers must agree with the body even with custom authentication.
            request.setValue(HTTPProtocol.version, forHTTPHeaderField: "MCP-Protocol-Version")
            request.setValue(nil, forHTTPHeaderField: "Mcp-Session-Id")
            request.setValue(nil, forHTTPHeaderField: "Last-Event-ID")
            try HTTPRoutingHeaders.apply(method: method, parameters: parameters, schema: schema, to: &request)
            let stream = HTTPResponseStream(
                request: request, session: session, maximumBufferedBytes: maximumMessageBytes
            )
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                stream.task.resume()
                defer { stream.task.cancel() }
                var iterator = stream.events.makeAsyncIterator()
                guard case let .response(response) = try await iterator.next() else {
                    throw HTTPClientError.invalidResponse
                }
                let bytes = HTTPResponseBytes(
                    iterator: iterator, maximumFrameBytes: maximumMessageBytes, consumed: stream.consumed
                )
                if response.statusCode == 200, response.mimeType?.lowercased() == "text/event-stream" {
                    for try await event in bytes.events {
                        if let result: Output = try await decode(
                            Data(event.data.utf8),
                            id: id,
                            status: 200,
                            notification: notification
                        ) {
                            return result
                        }
                    }
                } else {
                    var buffer = Data()
                    for try await byte in bytes {
                        guard buffer.count < maximumMessageBytes else { throw HTTPClientError.messageTooLarge }
                        buffer.append(byte)
                    }
                    if let result: Output = try await decode(
                        buffer,
                        id: id,
                        status: response.statusCode,
                        notification: notification
                    ) {
                        return result
                    }
                }
                throw HTTPClientError.invalidResponse
            } onCancel: { stream.task.cancel() }
        }

        private func decode<Output: Decodable & Sendable>(
            _ data: Data, id: ID, status: Int,
            notification: @Sendable (Value) async throws -> Void
        ) async throws -> Output? {
            let message = try? JSONDecoder().decode(HTTPJSONValue.self, from: data).value
            if let error = message?[httpField: "error"] {
                if let responseID = message?[httpField: "id"], responseID != .null,
                   try responseID != (HTTPProtocol.value(id)) {
                    throw HTTPClientError.invalidResponse
                }
                throw HTTPClientError.response(
                    status: status,
                    code: error[httpField: "code"]?.intValue,
                    message: error[httpField: "message"]?.stringValue,
                    data: error[httpField: "data"]
                )
            }
            guard (200 ..< 300).contains(status) else {
                throw HTTPClientError.response(status: status, code: nil, message: nil, data: nil)
            }
            guard let message, message[httpField: "jsonrpc"] == "2.0" else { throw HTTPClientError.invalidResponse }
            if let method = message[httpField: "method"]?.stringValue {
                guard message[httpField: "id"] == nil,
                      method.hasPrefix("notifications/") else { throw HTTPClientError.invalidResponse }
                try await notification(message)
                return nil
            }
            guard try message[httpField: "id"] == (HTTPProtocol.value(id)),
                  let result = message[httpField: "result"]
            else {
                throw HTTPClientError.invalidResponse
            }
            return try JSONDecoder().decode(Output.self, from: JSONEncoder().encode(result))
        }
    }

    /// Adapt Foundation's chunks to the SDK's existing SSE parser without another task or buffer queue.
    private struct HTTPResponseBytes: AsyncSequence {
        typealias Element = UInt8
        var iterator: AsyncThrowingStream<HTTPResponseStream.Event, Error>.Iterator
        let maximumFrameBytes: Int
        let consumed: @Sendable (Int) -> Void
        func makeAsyncIterator() -> Iterator {
            Iterator(source: iterator, maximumFrameBytes: maximumFrameBytes, consumed: consumed)
        }

        struct Iterator: AsyncIteratorProtocol {
            var source: AsyncThrowingStream<HTTPResponseStream.Event, Error>.Iterator
            let maximumFrameBytes: Int
            let consumed: @Sendable (Int) -> Void
            var chunk = Data().makeIterator()
            var frameBytes = 0
            var lineHasContent = false
            var previousWasCR = false

            mutating func next() async throws -> UInt8? {
                try Task.checkCancellation()
                var byte = chunk.next()
                while byte == nil {
                    guard let event = try await source.next() else { return nil }
                    guard case let .data(data) = event else { throw HTTPClientError.invalidResponse }
                    consumed(data.count)
                    chunk = data.makeIterator()
                    byte = chunk.next()
                }
                guard let byte else { return nil }
                frameBytes += 1
                guard frameBytes <= maximumFrameBytes else { throw HTTPClientError.messageTooLarge }
                // An empty SSE line ends a frame. CRLF is one line ending, not two.
                if byte == 13 || (byte == 10 && !previousWasCR) {
                    if !lineHasContent {
                        frameBytes = 0
                    }
                    lineHasContent = false
                } else if byte != 10 {
                    lineHasContent = true
                }
                previousWasCR = byte == 13
                return byte
            }
        }
    }
#endif
