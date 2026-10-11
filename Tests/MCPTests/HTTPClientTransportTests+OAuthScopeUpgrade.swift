@preconcurrency import Foundation
import Logging
import Testing

@testable import MCP

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

#if swift(>=6.1)
extension HTTPClientTransportTests {
    @Test("OAuth scope upgrade tracking is scoped per operation", .httpClientTransportSetup)
    func testOAuthScopeUpgradeTrackingPerOperation() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]

        let testEndpoint = URL(string: "https://localhost:8080/operation-tracking")!
        let resourceMetadataURL = URL(
            string: "https://localhost:8080/.well-known/oauth-protected-resource/operation-tracking")!
        let asMetadataURL = URL(
            string: "https://localhost:8080/.well-known/oauth-authorization-server/auth")!
        let tokenEndpointURL = URL(string: "https://localhost:8080/oauth/token")!
        let finalResponseData = #"{"jsonrpc":"2.0","result":{"ok":true},"id":62}"#.data(
            using: .utf8)!

        actor CallTracker {
            var tokenCalls = 0
            var opAForbiddenCalls = 0
            var opBForbiddenCalls = 0

            func nextTokenCall() -> Int {
                tokenCalls += 1
                return tokenCalls
            }

            func incrementOpAForbiddenCalls() {
                opAForbiddenCalls += 1
            }

            func incrementOpBForbiddenCalls() {
                opBForbiddenCalls += 1
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
                let body = String(data: request.readBody() ?? Data(), encoding: .utf8) ?? ""
                let isOperationA = body.contains(#""method":"tools/callA""#)
                let isOperationB = body.contains(#""method":"tools/callB""#)
                let authorization = request.value(forHTTPHeaderField: "Authorization")

                if authorization == nil {
                    let response = HTTPURLResponse(
                        url: url,
                        statusCode: 401,
                        httpVersion: "HTTP/1.1",
                        headerFields: [
                            "WWW-Authenticate":
                                "Bearer resource_metadata=\"\(resourceMetadataURL.absoluteString)\", scope=\"files:read\""
                        ])!
                    return (response, Data())
                }

                if isOperationA {
                    if authorization == "Bearer access-token-read"
                        || authorization == "Bearer access-token-read-write"
                    {
                        await tracker.incrementOpAForbiddenCalls()
                        let response = HTTPURLResponse(
                            url: url,
                            statusCode: 403,
                            httpVersion: "HTTP/1.1",
                            headerFields: [
                                "WWW-Authenticate":
                                    "Bearer error=\"insufficient_scope\", scope=\"files:write\", resource_metadata=\"\(resourceMetadataURL.absoluteString)\""
                            ])!
                        return (response, Data())
                    }

                    throw NSError(
                        domain: "MockURLProtocolError",
                        code: 0,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Unexpected Authorization for opA: \(authorization ?? "<none>")"
                        ])
                }

                if isOperationB {
                    if authorization == "Bearer access-token-read-write" {
                        await tracker.incrementOpBForbiddenCalls()
                        let response = HTTPURLResponse(
                            url: url,
                            statusCode: 403,
                            httpVersion: "HTTP/1.1",
                            headerFields: [
                                "WWW-Authenticate":
                                    "Bearer error=\"insufficient_scope\", scope=\"files:write\", resource_metadata=\"\(resourceMetadataURL.absoluteString)\""
                            ])!
                        return (response, Data())
                    }

                    if authorization == "Bearer access-token-opb" {
                        let response = HTTPURLResponse(
                            url: url,
                            statusCode: 200,
                            httpVersion: "HTTP/1.1",
                            headerFields: ["Content-Type": "application/json"])!
                        return (response, finalResponseData)
                    }

                    throw NSError(
                        domain: "MockURLProtocolError",
                        code: 0,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Unexpected Authorization for opB: \(authorization ?? "<none>")"
                        ])
                }

                throw NSError(
                    domain: "MockURLProtocolError",
                    code: 0,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Unexpected request body: \(body)"
                    ])

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
                #expect(
                    body.contains(
                        "resource=https%3A%2F%2Flocalhost%3A8080%2Foperation-tracking")
                )

                switch tokenCall {
                case 1:
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

                case 2:
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

                case 3:
                    #expect(body.contains("scope=files%3Aread%20files%3Awrite"))
                    let tokenResponse =
                        #"{ "access_token": "access-token-opb", "token_type": "Bearer", "expires_in": 3600 }"#
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
                                "Unexpected token call count: \(tokenCall)"
                        ])
                }

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
            authorizer: OAuthAuthorizer(configuration: .init(
                authentication: .none(clientID: "test-client"),
                retryPolicy: .init(maxAuthorizationAttempts: 8, maxScopeUpgradeAttempts: 1)
            )),
            logger: nil
        )

        try await transport.connect()

        let stream = await transport.receive()
        var iterator = stream.makeAsyncIterator()

        let operationAData = #"{"jsonrpc":"2.0","method":"tools/callA","id":61}"#.data(
            using: .utf8)!
        do {
            try await transport.send(operationAData)
            Issue.record("Expected operation A to fail after scope-upgrade retry limit")
        } catch let error as MCPError {
            guard case .internalError(let message) = error else {
                Issue.record("Expected MCPError.internalError, got \(error)")
                throw error
            }
            #expect(message?.contains("Access forbidden") ?? false)
        } catch {
            Issue.record("Expected MCPError, got \(error)")
            throw error
        }

        let operationBData = #"{"jsonrpc":"2.0","method":"tools/callB","id":62}"#.data(
            using: .utf8)!
        try await transport.send(operationBData)

        let received = try await iterator.next()
        #expect(received == finalResponseData)

        #expect(await tracker.tokenCalls == 3)
        #expect(await tracker.opAForbiddenCalls == 2)
        #expect(await tracker.opBForbiddenCalls == 1)

        await transport.disconnect()
    }
}
#endif
