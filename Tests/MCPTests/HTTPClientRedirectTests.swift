#if canImport(EventSource)
    import Foundation
    @testable import MCP
    import NIOCore
    import NIOHTTP1
    import NIOPosix
    import Testing

    @Suite("HTTP endpoint redirects", .timeLimit(.minutes(1)))
    struct HTTPClientRedirectTests {
        @Test("Trailing slash redirects preserve discovery and tool POSTs", arguments: [307, 308])
        func redirectedEndpoint(status: Int) async throws {
            let beforeRedirect = HTTPRequestLedger()
            let afterRedirect = HTTPRequestLedger()
            let redirectedCredentials = HTTPRequestLedger()
            let server = try await RedirectTestServer.start { request, bytes in
                let credentials: Value = [
                    "authorization": request.headers.first(name: "Authorization").map(Value.string) ?? .null,
                    "apiKey": request.headers.first(name: "X-API-Key").map(Value.string) ?? .null,
                ]
                if request.uri == "/control/" {
                    return .init(status: status, headers: ["Location": "/control"], body: Data())
                }
                if request.uri == "/control" {
                    await redirectedCredentials.append(credentials)
                    return try .json(["ok": true])
                }
                let body = try JSONDecoder().decode(HTTPJSONValue.self, from: bytes).value
                #expect(request.method == .POST)
                #expect(request.headers.first(name: "MCP-Protocol-Version") == "2026-07-28")
                if request.uri == "/mcp/" {
                    #expect(request.headers.first(name: "Authorization") == "Bearer fixture-only")
                    await beforeRedirect.append(body)
                    return .init(status: status, headers: ["Location": "/mcp"], body: Data())
                }
                #expect(request.uri == "/mcp")
                await redirectedCredentials.append(credentials)
                await afterRedirect.append(body)
                switch body[httpField: "method"]?.stringValue {
                case "server/discover": return try .json(httpResult(body, httpDiscovery))
                case "tools/list": return try .json(httpResult(body, [
                    "tools": [["name": "echo", "inputSchema": ["type": "object", "properties": [:]]]],
                ]))
                case "tools/call": return try .json(httpResult(body, [
                    "content": [["type": "text", "text": "completed"]],
                ]))
                default: throw HTTPClientError.invalidResponse
                }
            }
            let client = HTTPClient(name: "tests", version: "1")
            let nativeSession = URLSession(configuration: .default)
            defer { nativeSession.invalidateAndCancel() }
            do {
                // Compare credential handling with Foundation itself; do not impose
                // different rules in the SDK or assume which headers it preserves.
                let controlURL = try #require(URL(string: "/control/", relativeTo: server.endpoint)?.absoluteURL)
                var control = Self.authorized(URLRequest(url: controlURL))
                control.httpMethod = "POST"
                control.httpBody = Data("{}".utf8)
                control.setValue("application/json", forHTTPHeaderField: "Content-Type")
                let (_, response) = try await nativeSession.data(for: control)
                #expect((response as? HTTPURLResponse)?.statusCode == 200)
                let info = try await client.connect(endpoint: server.endpoint, requestModifier: Self.authorized)
                #expect(info.protocolVersion == "2026-07-28")
                let listing = try await client.send(ListTools.request(.init()))
                #expect(try await listing.value.tools.map(\.name) == ["echo"])
                let call = try await client.callTool(name: "echo", arguments: ["message": "redirected"])
                #expect(try await call.value.content == [.text(text: "completed", annotations: nil, _meta: nil)])
                let original = await beforeRedirect.requests
                let redirected = await afterRedirect.requests
                #expect(original == redirected)
                #expect(redirected.compactMap { $0[httpField: "method"]?.stringValue } == [
                    "server/discover", "tools/list", "tools/call",
                ])
                let credentials = await redirectedCredentials.requests
                let nativeCredentials = try #require(credentials.first)
                #expect(credentials.count == 4)
                #expect(credentials.dropFirst().allSatisfy { $0 == nativeCredentials })
                await client.disconnect()
                try await server.channel.close()
            } catch {
                await client.disconnect()
                try? await server.channel.close()
                throw error
            }
        }

        private static func authorized(_ request: URLRequest) -> URLRequest {
            var request = request
            request.setValue("Bearer fixture-only", forHTTPHeaderField: "Authorization")
            request.setValue("fixture-api-key", forHTTPHeaderField: "X-API-Key")
            return request
        }
    }

    /// Uses a loopback socket so Foundation constructs and follows the redirect itself.
    private struct RedirectTestServer {
        typealias Responder = @Sendable (HTTPRequestHead, Data) async throws -> HTTPClientFixture.Reply
        let channel: any Channel
        let endpoint: URL

        static func start(respond: @escaping Responder) async throws -> Self {
            let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .childChannelInitializer { channel in
                    channel.pipeline.configureHTTPServerPipeline().flatMapThrowing {
                        try channel.pipeline.syncOperations.addHandler(Handler(respond: respond))
                    }
                }
                .bind(host: "127.0.0.1", port: 0).get()
            let port = try #require(channel.localAddress?.port)
            let endpoint = try #require(URL(string: "http://127.0.0.1:\(port)/mcp/"))
            return Self(channel: channel, endpoint: endpoint)
        }

        private final class Handler: ChannelInboundHandler {
            typealias InboundIn = HTTPServerRequestPart
            private let respond: Responder
            private var head: HTTPRequestHead?
            private var body = Data()

            init(respond: @escaping Responder) {
                self.respond = respond
            }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                switch unwrapInboundIn(data) {
                case .head(let head):
                    self.head = head
                    body = Data()
                case .body(let buffer):
                    body.append(contentsOf: buffer.readableBytesView)
                case .end:
                    guard let head else { return }
                    let channel = context.channel
                    let bytes = body
                    let respond = respond
                    self.head = nil
                    Task {
                        do {
                            let reply = try await respond(head, bytes)
                            var headers = HTTPHeaders(reply.headers.map { ($0.key, $0.value) })
                            headers.replaceOrAdd(name: "Content-Length", value: String(reply.body.count))
                            headers.replaceOrAdd(name: "Connection", value: "close")
                            let response = HTTPResponseHead(
                                version: .http1_1, status: .init(statusCode: reply.status), headers: headers
                            )
                            try await channel.writeAndFlush(HTTPServerResponsePart.head(response))
                            let buffer = channel.allocator.buffer(bytes: reply.body)
                            try await channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buffer)))
                            try await channel.writeAndFlush(HTTPServerResponsePart.end(nil))
                        } catch {
                            Issue.record(error)
                        }
                        try? await channel.close()
                    }
                }
            }
        }
    }
#endif
