@preconcurrency import Foundation
import Logging
import Testing

@testable import MCP

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

#if swift(>=6.1)
extension HTTPClientTransportTests {
    @Test("OAuth scope step-up retries after 403 insufficient_scope", .httpClientTransportSetup)
    func testOAuthStepUpRetryAfter403InsufficientScope() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]

        let testEndpoint = URL(string: "https://localhost:8080/step-up")!
        let resourceMetadataURL = URL(
            string: "https://localhost:8080/.well-known/oauth-protected-resource/step-up")!
        let asMetadataURL = URL(
            string: "https://localhost:8080/.well-known/oauth-authorization-server/auth")!
        let tokenEndpointURL = URL(string: "https://localhost:8080/oauth/token")!
        let finalResponseData = #"{"jsonrpc":"2.0","result":{"ok":true},"id":43}"#.data(
            using: .utf8)!

        actor CallTracker {
            var tokenCalls = 0

            func nextTokenCall() -> Int {
                tokenCalls += 1
                return tokenCalls
            }
        }
        let tracker = CallTracker()

        await MockURLProtocol.requestHandlerStorage.setHandler {
            [tracker, testEndpoint, resourceMetadataURL, asMetadataURL, tokenEndpointURL, finalResponseData] request in
            guard let url = request.url else {
                throw NSError(
                    domain: "MockURLProtocolError",
                    code: 0,
                    userInfo: [NSLocalizedDescriptionKey: "Missing request URL"])
            }

            switch url {
            case testEndpoint:
                switch request.value(forHTTPHeaderField: "Authorization") {
                case nil:
                    let response = HTTPURLResponse(
                        url: url,
                        statusCode: 401,
                        httpVersion: "HTTP/1.1",
                        headerFields: [
                            "WWW-Authenticate":
                                "Bearer resource_metadata=\"\(resourceMetadataURL.absoluteString)\", scope=\"files:read\""
                        ])!
                    return (response, Data())

                case "Bearer access-token-read":
                    let response = HTTPURLResponse(
                        url: url,
                        statusCode: 403,
                        httpVersion: "HTTP/1.1",
                        headerFields: [
                            "WWW-Authenticate":
                                "Bearer error=\"insufficient_scope\", scope=\"files:write\", resource_metadata=\"\(resourceMetadataURL.absoluteString)\", error_description=\"Additional file write permission required\""
                        ])!
                    return (response, Data())

                case "Bearer access-token-read-write":
                    let response = HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "application/json"])!
                    return (response, finalResponseData)

                default:
                    throw NSError(
                        domain: "MockURLProtocolError",
                        code: 0,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Unexpected Authorization value: \(request.value(forHTTPHeaderField: "Authorization") ?? "<none>")"
                        ])
                }

            case resourceMetadataURL:
                let metadata =
                    #"{ "authorization_servers": ["https://localhost:8080/auth"], "scopes_supported": ["files:read","files:write"] }"#
                    .data(using: .utf8)!
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"])!
                return (response, metadata)

            case asMetadataURL:
                let metadata = #"{ "issuer": "https://localhost:8080/auth", "token_endpoint": "https://localhost:8080/oauth/token" }"#
                    .data(using: .utf8)!
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"])!
                return (response, metadata)

            case tokenEndpointURL:
                let tokenCall = await tracker.nextTokenCall()
                let body = String(data: request.readBody() ?? Data(), encoding: .utf8) ?? ""
                #expect(body.contains("grant_type=client_credentials"))
                #expect(body.contains("client_id=test-client"))
                #expect(body.contains("resource=https%3A%2F%2Flocalhost%3A8080%2Fstep-up"))

                if tokenCall == 1 {
                    #expect(body.contains("scope=files%3Aread"))
                    let tokenResponse =
                        #"{ "access_token": "access-token-read", "token_type": "Bearer", "expires_in": 3600 }"#
                        .data(using: .utf8)!
                    let response = HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "application/json"])!
                    return (response, tokenResponse)
                }

                #expect(tokenCall == 2)
                #expect(body.contains("scope=files%3Aread%20files%3Awrite"))
                let tokenResponse =
                    #"{ "access_token": "access-token-read-write", "token_type": "Bearer", "expires_in": 3600 }"#
                    .data(using: .utf8)!
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"])!
                return (response, tokenResponse)

            default:
                throw NSError(
                    domain: "MockURLProtocolError",
                    code: 0,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Unexpected URL: \(url.absoluteString)"
                    ])
            }
        }

        let transport = HTTPClientTransport(
            endpoint: testEndpoint,
            configuration: configuration,
            streaming: false,
            authorizer: OAuthAuthorizer(configuration: .init(authentication: .none(clientID: "test-client"))),
            logger: nil
        )

        try await transport.connect()
        let messageData = #"{"jsonrpc":"2.0","method":"ping","id":43}"#.data(using: .utf8)!
        try await transport.send(messageData)

        let stream = await transport.receive()
        var iterator = stream.makeAsyncIterator()
        let received = try await iterator.next()
        #expect(received == finalResponseData)
        #expect(await tracker.tokenCalls == 2)

        await transport.disconnect()
    }
}
#endif
