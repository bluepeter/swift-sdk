@preconcurrency import Foundation
import Logging
import Testing

@testable import MCP

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

#if swift(>=6.1) && !canImport(FoundationNetworking)
extension HTTPClientTransportTests {
    @Test("Receive Server-Sent Event (SSE)", .httpClientTransportSetup)
    func testReceiveSSE() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]

        let transport = HTTPClientTransport(
            endpoint: testEndpoint,
            configuration: configuration,
            streaming: true,
            sseInitializationTimeout: 1,
            logger: nil
        )

        let eventString = "id: event1\ndata: {\"key\":\"value\"}\n\n"
        let sseEventData = eventString.data(using: .utf8)!

        // First, set up a handler for the initial POST that will provide a session ID
        await MockURLProtocol.requestHandlerStorage.setHandler {
            [testEndpoint] (request: URLRequest) in
            let response = HTTPURLResponse(
                url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": "text/plain",
                    "Mcp-Session-Id": "test-session-123",
                ])!
            return (response, Data())
        }

        // Connect and send a dummy message to get the session ID
        try await transport.connect()
        try await transport.send(Data())

        // Now set up the handler for the SSE GET request
        await MockURLProtocol.requestHandlerStorage.setHandler {
            [testEndpoint, sseEventData] (request: URLRequest) in  // sseEventData is now empty Data()
            #expect(request.url == testEndpoint)
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
            #expect(
                request.value(forHTTPHeaderField: "MCP-Session-Id") == "test-session-123")

            let response = HTTPURLResponse(
                url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"])!

            return (response, sseEventData)  // Will return empty Data for SSE
        }

        try await Task.sleep(for: .milliseconds(100))

        let stream = await transport.receive()
        var iterator = stream.makeAsyncIterator()

        let expectedData = #"{"key":"value"}"#.data(using: .utf8)!
        let receivedData = try await iterator.next()

        #expect(receivedData == expectedData)

        await transport.disconnect()
    }

    @Test("Receive Server-Sent Event (SSE) (CR-NL)", .httpClientTransportSetup)
    func testReceiveSSE_CRNL() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]

        let transport = HTTPClientTransport(
            endpoint: testEndpoint,
            configuration: configuration,
            streaming: true,
            sseInitializationTimeout: 1,
            logger: nil
        )

        let eventString = "id: event1\r\ndata: {\"key\":\"value\"}\r\n\n"
        let sseEventData = eventString.data(using: .utf8)!

        // First, set up a handler for the initial POST that will provide a session ID
        // Use text/plain to prevent its (empty) body from being yielded to messageStream
        await MockURLProtocol.requestHandlerStorage.setHandler {
            [testEndpoint] (request: URLRequest) in
            let response = HTTPURLResponse(
                url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": "text/plain",
                    "Mcp-Session-Id": "test-session-123",
                ])!
            return (response, Data())
        }

        // Connect and send a dummy message to get the session ID
        try await transport.connect()
        try await transport.send(Data())

        // Now set up the handler for the SSE GET request
        await MockURLProtocol.requestHandlerStorage.setHandler {
            [testEndpoint, sseEventData] (request: URLRequest) in
            #expect(request.url == testEndpoint)
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
            #expect(
                request.value(forHTTPHeaderField: "MCP-Session-Id") == "test-session-123")

            let response = HTTPURLResponse(
                url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"])!

            return (response, sseEventData)
        }

        try await Task.sleep(for: .milliseconds(100))

        let stream = await transport.receive()
        var iterator = stream.makeAsyncIterator()

        let expectedData = #"{"key":"value"}"#.data(using: .utf8)!
        let receivedData = try await iterator.next()

        #expect(receivedData == expectedData)

        await transport.disconnect()
    }

    @Test(
        "Client with HTTP Transport complete flow", .httpClientTransportSetup,
        .timeLimit(.minutes(1)))
    func testClientFlow() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]

        let transport = HTTPClientTransport(
            endpoint: testEndpoint,
            configuration: configuration,
            streaming: false,
            logger: nil
        )

        let client = Client(name: "TestClient", version: "1.0.0")

        // Use an actor to track request sequence
        actor RequestTracker {
            enum RequestType {
                case initialize
                case callTool
            }

            private(set) var lastRequest: RequestType?

            func setRequest(_ type: RequestType) {
                lastRequest = type
            }

            func getLastRequest() -> RequestType? {
                return lastRequest
            }
        }

        let tracker = RequestTracker()

        // Setup mock responses
        await MockURLProtocol.requestHandlerStorage.setHandler {
            [testEndpoint, tracker] (request: URLRequest) in
            switch request.httpMethod {
            case "GET":
                #expect(
                    request.allHTTPHeaderFields?["Accept"]?.contains("text/event-stream")
                        == true)
            case "POST":
                #expect(
                    request.allHTTPHeaderFields?["Accept"]?.contains("application/json")
                        == true
                )
            default:
                Issue.record(
                    "Unsupported HTTP method \(String(describing: request.httpMethod))")
            }

            #expect(request.url == testEndpoint)

            let bodyData = request.readBody()

            guard let bodyData = bodyData,
                let json = try JSONSerialization.jsonObject(with: bodyData)
                    as? [String: Any],
                let method = json["method"] as? String
            else {
                throw NSError(
                    domain: "MockURLProtocolError", code: 0,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Invalid JSON-RPC message \(#file):\(#line)"
                    ])
            }

            if method == "initialize" {
                await tracker.setRequest(.initialize)

                let requestID = json["id"] as! String
                let result = Initialize.Result(
                    protocolVersion: Version.latest,
                    capabilities: .init(tools: .init()),
                    serverInfo: .init(name: "Mock Server", version: "0.0.1"),
                    instructions: nil
                )
                let response = Initialize.response(id: .string(requestID), result: result)
                let responseData = try JSONEncoder().encode(response)

                let httpResponse = HTTPURLResponse(
                    url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"])!
                return (httpResponse, responseData)
            } else if method == "tools/call" {
                // Verify initialize was called first
                if let lastRequest = await tracker.getLastRequest(),
                    lastRequest != .initialize
                {
                    #expect(Bool(false), "Initialize should be called before callTool")
                }

                await tracker.setRequest(.callTool)

                let params = json["params"] as? [String: Any]
                let toolName = params?["name"] as? String
                #expect(toolName == "calculator")

                let requestID = json["id"] as! String
                let result = CallTool.Result(content: [.text(text: "42", annotations: nil, _meta: nil)])
                let response = CallTool.response(id: .string(requestID), result: result)
                let responseData = try JSONEncoder().encode(response)

                let httpResponse = HTTPURLResponse(
                    url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"])!
                return (httpResponse, responseData)
            } else if method == "notifications/initialized" {
                // Ignore initialized notifications
                let httpResponse = HTTPURLResponse(
                    url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"])!
                return (httpResponse, Data())
            } else {
                throw NSError(
                    domain: "MockURLProtocolError", code: 0,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Unexpected request method: \(method) \(#file):\(#line)"
                    ])
            }
        }

        // Step 1: Initialize client
        let initResult = try await client.connect(transport: transport)
        #expect(initResult.protocolVersion == Version.latest)
        #expect(initResult.capabilities.tools != nil)

        // Step 2: Call a tool
        let toolResult = try await client.callTool(name: "calculator")
        #expect(toolResult.content.count == 1)
        if case let .text(text, _, _) = toolResult.content[0] {
            #expect(text == "42")
        } else {
            #expect(Bool(false), "Expected text content")
        }

        // Step 3: Verify request sequence
        #expect(await tracker.getLastRequest() == .callTool)

        // Step 4: Disconnect
        await client.disconnect()
    }

    @Test("Request modifier functionality", .httpClientTransportSetup)
    func testRequestModifier() async throws {
        let testEndpoint = URL(string: "https://api.example.com/mcp")!
        let testToken = "test-bearer-token-12345"

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]

        await MockURLProtocol.requestHandlerStorage.setHandler {
            [testEndpoint, testToken] (request: URLRequest) in
            // Verify the Authorization header was added by the requestModifier
            #expect(
                request.value(forHTTPHeaderField: "Authorization") == "Bearer \(testToken)")

            // Return a successful response
            let response = HTTPURLResponse(
                url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            return (response, Data())
        }

        // Create transport with requestModifier that adds Authorization header
        let transport = HTTPClientTransport(
            endpoint: testEndpoint,
            configuration: configuration,
            streaming: false,
            requestModifier: { request in
                var modifiedRequest = request
                modifiedRequest.addValue(
                    "Bearer \(testToken)", forHTTPHeaderField: "Authorization")
                return modifiedRequest
            },
            logger: nil
        )

        try await transport.connect()

        let messageData = #"{"jsonrpc":"2.0","method":"test","id":5}"#.data(using: .utf8)!

        try await transport.send(messageData)
        await transport.disconnect()
    }

    @Test("Send With Protocol Version Header", .httpClientTransportSetup)
    func testProtocolVersionHeader() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]

        let protocolVersion = "2025-11-25"
        let transport = HTTPClientTransport(
            endpoint: testEndpoint,
            configuration: configuration,
            streaming: false,
            protocolVersion: protocolVersion,
            logger: nil
        )
        try await transport.connect()

        let messageData = #"{"jsonrpc":"2.0","method":"test","id":6}"#.data(using: .utf8)!

        await MockURLProtocol.requestHandlerStorage.setHandler {
            [testEndpoint, protocolVersion] (request: URLRequest) in
            // Verify the protocol version header is present
            #expect(
                request.value(forHTTPHeaderField: "MCP-Protocol-Version")
                    == protocolVersion)

            let response = HTTPURLResponse(
                url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            return (response, Data())
        }

        try await transport.send(messageData)
        await transport.disconnect()
    }
}
#endif
