#if canImport(EventSource)
    import Foundation
    @testable import MCP

    final class HTTPClientFixture: @unchecked Sendable {
        struct Reply: Sendable {
            var status = 200
            var headers = ["Content-Type": "application/json"]
            let body: Data
            var additionalBody: AsyncThrowingStream<Data, Error>?
            static func json(_ value: Value, status: Int = 200) throws -> Self {
                try Self(status: status, body: JSONEncoder().encode(value))
            }
        }

        typealias Handler = @Sendable (URLRequest, Value) async throws -> Reply
        let endpoint: URL
        let session: URLSession
        init(handler: @escaping Handler) {
            let host = UUID().uuidString.lowercased() + ".invalid"
            endpoint = URL(string: "https://\(host)/mcp")!
            FixtureURLProtocol.register(host: host, handler: handler)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [FixtureURLProtocol.self]
            session = URLSession(configuration: configuration)
        }

        deinit {
            session.invalidateAndCancel()
            FixtureURLProtocol.unregister(host: endpoint.host!)
        }
    }

    private final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
        private static let lock = NSLock()
        private nonisolated(unsafe) static var handlers: [String: HTTPClientFixture.Handler] = [:]
        private let taskLock = NSLock()
        private var work: Task<Void, Never>?
        static func register(host: String, handler: @escaping HTTPClientFixture.Handler) {
            lock.withLock { handlers[host] = handler }
        }

        static func unregister(host: String) {
            _ = lock.withLock { handlers.removeValue(forKey: host) }
        }

        override class func canInit(with request: URLRequest) -> Bool {
            lock.withLock { handlers[request.url?.host ?? ""] != nil }
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            let handler = Self.lock.withLock { Self.handlers[request.url?.host ?? ""] }
            taskLock.withLock {
                work = Task { @Sendable [self, handler] in
                    do {
                        var body = request.httpBody ?? Data()
                        if let input = request.httpBodyStream {
                            input.open()
                            defer { input.close() }
                            var bytes = [UInt8](repeating: 0, count: 4096)
                            while input.hasBytesAvailable {
                                let count = input.read(&bytes, maxLength: bytes.count)
                                if count <= 0 {
                                    break
                                }
                                body.append(contentsOf: bytes.prefix(count))
                            }
                        }
                        let value = body.isEmpty ? Value.null : try JSONDecoder().decode(HTTPJSONValue.self, from: body)
                            .value
                        guard let handler else { throw HTTPClientError.invalidResponse }
                        let reply = try await handler(request, value)
                        try Task.checkCancellation()
                        let response = HTTPURLResponse(
                            url: request.url!,
                            statusCode: reply.status,
                            httpVersion: "HTTP/1.1",
                            headerFields: reply.headers
                        )!
                        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                        client?.urlProtocol(self, didLoad: reply.body)
                        if let additionalBody = reply.additionalBody {
                            for try await chunk in additionalBody {
                                try Task.checkCancellation()
                                client?.urlProtocol(self, didLoad: chunk)
                            }
                        }
                        try Task.checkCancellation()
                        client?.urlProtocolDidFinishLoading(self)
                    } catch { client?.urlProtocol(self, didFailWithError: error) }
                }
            }
        }

        override func stopLoading() {
            taskLock.withLock { work?.cancel() }
        }
    }

    actor HTTPRequestLedger {
        private(set) var requests: [Value] = []
        func append(_ request: Value) {
            requests.append(request)
        }
    }

    func httpResult(_ request: Value, _ result: Value) -> Value {
        ["jsonrpc": "2.0", "id": request[httpField: "id"] ?? .null, "result": result]
    }

    let httpDiscovery: Value = [
        "resultType": "complete",
        "supportedVersions": ["2026-07-28"],
        "capabilities": ["tools": [:]]
    ]
    let httpInput: Value = [
        "resultType": "input_required",
        "requestState": "data:text/plain;base64,b3BhcXVl",
        "inputRequests": [
            "confirmation": ["method": "elicitation/create", "params": [
                "message": "Confirm", "requestedSchema": [
                    "type": "object",
                    "properties": ["confirmed": ["type": "boolean"]]
                ]
            ]]
        ]
    ]
#endif
