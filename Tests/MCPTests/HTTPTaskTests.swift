#if canImport(EventSource)
    import Foundation
    @testable import MCP
    import Testing

    @Suite("2026 Tasks HTTP extension", .timeLimit(.minutes(1)))
    struct HTTPTaskTests {
        @Test("Capability is opt in per call; task handles and lifecycle calls preserve identity")
        func lifecycle() async throws {
            let ledger = HTTPRequestLedger()
            let fixture = HTTPClientFixture { request, body in
                await ledger.append(body)
                let method = body[httpField: "method"]?.stringValue
                if method == "server/discover" {
                    return try .json(httpResult(body, taskDiscovery))
                }
                let capability = body[httpField: "params"]?[httpField: "_meta"]?[
                    httpField: HTTPProtocol.capabilitiesKey
                ]?[httpField: "extensions"]?[httpField: HTTPTask.extensionIdentifier]
                #expect(capability == .object([:]))
                if method?.hasPrefix("tasks/") == true {
                    #expect(request.value(forHTTPHeaderField: "Mcp-Name") == "test-task")
                }
                switch method {
                case "tools/call": return try .json(httpResult(body, taskValue("working", tag: "task")))
                case "tasks/get": return try .json(httpResult(body, taskValue("completed")))
                case "tasks/update", "tasks/cancel":
                    #expect(body[httpField: "params"]?[httpField: "taskId"] == "test-task")
                    return try .json(httpResult(body, ["resultType": "complete"]))
                default: throw HTTPClientError.invalidResponse
                }
            }
            let client = HTTPClient(name: "tests", version: "1")
            let connection = try await client.connect(endpoint: fixture.endpoint, session: fixture.session)
            #expect(connection.supportsTasks)
            let operation = try await client.callTool(name: "work", taskHandler: { task in
                #expect(task.taskId == "test-task")
                try await client.updateTask(task.taskId, responses: ["form": ["action": "decline"]])
                try await client.cancelTask(task.taskId)
                return try #require(try await client.getTask(task.taskId).result)
            })
            #expect(try await operation.value.content == [.text(text: "completed", annotations: nil, _meta: nil)])
            #expect(await ledger.requests.filter { $0[httpField: "method"] == "tools/call" }.count == 1)
            await client.disconnect()
        }

        @Test("A client without a task handler never advertises the extension")
        func noHandler() async throws {
            let fixture = HTTPClientFixture { _, body in
                if body[httpField: "method"] == "server/discover" {
                    return try .json(httpResult(body, taskDiscovery))
                }
                #expect(body[httpField: "params"]?[httpField: "_meta"]?[
                    httpField: HTTPProtocol.capabilitiesKey
                ]?[httpField: "extensions"] == nil)
                return try .json(httpResult(body, taskValue("working", tag: "task")))
            }
            let client = HTTPClient(name: "tests", version: "1")
            _ = try await client.connect(endpoint: fixture.endpoint, session: fixture.session)
            let operation = try await client.callTool(name: "work")
            await #expect(throws: HTTPClientError.self) { try await operation.value }
            await client.disconnect()
        }

        @Test("Task input uses the existing form decoder and preserves declined responses")
        func formInput() async throws {
            var value = taskValue("input_required").objectValue!
            value["inputRequests"] = ["confirmation": ["method": "elicitation/create", "params": [
                "message": "Confirm", "requestedSchema": [
                    "$schema": "https://json-schema.org/draft/2020-12/schema", "type": "object", "properties": [:]
                ]
            ]]]
            let state = try decode(HTTPTaskState.self, .object(value))
            let responses = try await state.inputResponses { _ in .init(action: .decline) }
            #expect(responses["confirmation"]?[httpField: "action"] == "decline")
        }

        @Test("Malformed terminal states fail instead of becoming empty successes", arguments: ["completed", "failed", "input_required"])
        func malformedState(status: String) throws {
            var value = taskValue(status).objectValue!
            value["result"] = nil
            #expect(throws: (any Error).self) { try decode(HTTPTaskState.self, .object(value)) }
        }

        @Test("Task failures retain their JSON RPC error and finite TTL is validated")
        func failureAndTTL() throws {
            var value = taskValue("failed").objectValue!
            value["error"] = ["code": -32603, "message": "failed"]
            let state = try decode(HTTPTaskState.self, .object(value))
            #expect(state.error?.code == -32603)
            #expect(state.error?.message == "failed")
            value["ttlMs"] = -1
            #expect(throws: HTTPClientError.self) { try decode(HTTPTask.self, .object(value)) }
        }

        private func decode<T: Decodable>(_ type: T.Type, _ value: Value) throws -> T {
            try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
        }
    }

    private let taskDiscovery: Value = [
        "supportedVersions": ["2026-07-28"],
        "capabilities": ["tools": [:], "extensions": [HTTPTask.extensionIdentifier: [:]]]
    ]

    private func taskValue(_ status: String, tag: String = "complete") -> Value {
        var value: [String: Value] = [
            "resultType": .string(tag), "taskId": "test-task", "status": .string(status),
            "createdAt": "2026-10-15T00:00:00Z", "lastUpdatedAt": "2026-10-15T00:00:00Z",
            "ttlMs": .null, "pollIntervalMs": 1000
        ]
        if status == "completed" { value["result"] = ["content": [["type": "text", "text": "completed"]]] }
        return .object(value)
    }
#endif
