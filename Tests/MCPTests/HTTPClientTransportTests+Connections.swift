@preconcurrency import Foundation
import Logging
import Testing

@testable import MCP

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

#if swift(>=6.1)
extension HTTPClientTransportTests {
    @Test("Connect and Disconnect", .httpClientTransportSetup)
    func testConnectAndDisconnect() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]

        let transport = HTTPClientTransport(
            endpoint: testEndpoint,
            configuration: configuration,
            streaming: false,
            logger: nil
        )

        try await transport.connect()
        await transport.disconnect()
    }

    @Test("Send and Receive JSON Response", .httpClientTransportSetup)
    func testSendAndReceiveJSON() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]

        let transport = HTTPClientTransport(
            endpoint: testEndpoint,
            configuration: configuration,
            streaming: false,
            logger: nil
        )
        try await transport.connect()

        let messageData = #"{"jsonrpc":"2.0","method":"initialize","id":1}"#.data(using: .utf8)!
        let responseData = #"{"jsonrpc":"2.0","result":{},"id":1}"#.data(using: .utf8)!

        await MockURLProtocol.requestHandlerStorage.setHandler {
            [testEndpoint] (request: URLRequest) in
            #expect(request.url == testEndpoint)
            #expect(request.httpMethod == "POST")
            #expect(request.readBody() == messageData)
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            #expect(
                request.value(forHTTPHeaderField: "Accept")
                    == "application/json, text/event-stream"
            )

            let response = HTTPURLResponse(
                url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            return (response, responseData)
        }

        try await transport.send(messageData)

        let stream = await transport.receive()
        var iterator = stream.makeAsyncIterator()
        let receivedData = try await iterator.next()

        #expect(receivedData == responseData)
    }

    @Test("Send and Receive Session ID", .httpClientTransportSetup)
    func testSendAndReceiveSessionID() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]

        let transport = HTTPClientTransport(
            endpoint: testEndpoint,
            configuration: configuration,
            streaming: false,
            logger: nil
        )
        try await transport.connect()

        let messageData = #"{"jsonrpc":"2.0","method":"initialize","id":1}"#.data(using: .utf8)!
        let newSessionID = "session-12345"

        await MockURLProtocol.requestHandlerStorage.setHandler {
            [testEndpoint] (request: URLRequest) in
            #expect(request.value(forHTTPHeaderField: "MCP-Session-Id") == nil)
            let response = HTTPURLResponse(
                url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": "application/json",
                    "MCP-Session-Id": newSessionID,
                ])!
            return (response, Data())
        }

        try await transport.send(messageData)

        let storedSessionID = await transport.sessionID
        #expect(storedSessionID == newSessionID)
    }

    @Test("Send With Existing Session ID", .httpClientTransportSetup)
    func testSendWithExistingSessionID() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]

        let transport = HTTPClientTransport(
            endpoint: testEndpoint,
            configuration: configuration,
            streaming: false,
            logger: nil
        )
        try await transport.connect()

        let initialSessionID = "existing-session-abc"
        let firstMessageData = #"{"jsonrpc":"2.0","method":"initialize","id":1}"#.data(
            using: .utf8)!
        let secondMessageData = #"{"jsonrpc":"2.0","method":"ping","id":2}"#.data(
            using: .utf8)!

        await MockURLProtocol.requestHandlerStorage.setHandler {
            [testEndpoint] (request: URLRequest) in
            #expect(request.readBody() == firstMessageData)
            #expect(request.value(forHTTPHeaderField: "MCP-Session-Id") == nil)
            let response = HTTPURLResponse(
                url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": "application/json",
                    "MCP-Session-Id": initialSessionID,
                ])!
            return (response, Data())
        }
        try await transport.send(firstMessageData)
        #expect(await transport.sessionID == initialSessionID)

        await MockURLProtocol.requestHandlerStorage.setHandler {
            [testEndpoint] (request: URLRequest) in
            #expect(request.readBody() == secondMessageData)
            #expect(request.value(forHTTPHeaderField: "MCP-Session-Id") == initialSessionID)

            let response = HTTPURLResponse(
                url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            return (response, Data())
        }
        try await transport.send(secondMessageData)

        #expect(await transport.sessionID == initialSessionID)
    }
}
#endif
