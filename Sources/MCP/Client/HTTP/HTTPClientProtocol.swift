import Foundation

/// Errors retain protocol data for version negotiation without interpreting server text.
public enum HTTPClientError: Error, Sendable {
    case response(status: Int, code: Int?, message: String?, data: Value?)
    case invalidResponse
    case unsupportedVersion
    case unsupportedInput
    case unsupportedInputMethod
    case unsupportedURLInput
    case inputUnavailable
    case inputRoundLimit
    case invalidHeaderAnnotation
    case messageTooLarge
}

/// Connection metadata shared by discovery and the older initialize handshake.
public struct HTTPConnectionInfo: Sendable {
    public let protocolVersion: String
    public let capabilities: Server.Capabilities
    public let instructions: String?
    var subscribedToToolChanges: Bool = false
    public internal(set) var supportsTasks = false
    public var supportsToolListChanges: Bool {
        protocolVersion == HTTPProtocol.version ? subscribedToToolChanges : capabilities.tools?.listChanged == true
    }
}

/// Only the 2026 form flow is implemented here. URL, sampling, and roots are not advertised.
public typealias HTTPFormHandler = @Sendable (CreateElicitation.Parameters.FormParameters) async throws
    -> CreateElicitation.Result

struct HTTPDiscovery: Decodable, Sendable {
    let supportedVersions: [String]
    let capabilities: Server.Capabilities
    let instructions: String?
    let supportsTasks: Bool

    enum CodingKeys: String, CodingKey { case supportedVersions, capabilities, instructions }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        supportedVersions = try container.decode([String].self, forKey: .supportedVersions)
        capabilities = try container.decode(Server.Capabilities.self, forKey: .capabilities)
        instructions = try container.decodeIfPresent(String.self, forKey: .instructions)
        let raw = try container.decode(HTTPJSONValue.self, forKey: .capabilities).value
        supportsTasks = raw[httpField: "extensions"]?[httpField: HTTPTask.extensionIdentifier]?.objectValue != nil
    }
}

struct HTTPInputRequired: Decodable, Sendable {
    struct Input: Decodable, Sendable {
        let method: String
        let params: Value

        enum CodingKeys: String, CodingKey { case method, params }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            method = try container.decode(String.self, forKey: .method)
            params = try container.decode(HTTPJSONValue.self, forKey: .params).value
        }

        func form() throws -> CreateElicitation.Parameters.FormParameters {
            guard method == CreateElicitation.name else { throw HTTPClientError.unsupportedInputMethod }
            if params[httpField: "mode"] == .string("url") {
                throw HTTPClientError.unsupportedURLInput
            }
            guard params[httpField: "mode"] == nil || params[httpField: "mode"] == .string("form") else {
                throw HTTPClientError.unsupportedInput
            }
            guard let message = params[httpField: "message"]?.stringValue,
                  let schema = params[httpField: "requestedSchema"]?.objectValue,
                  schema["type"] == "object",
                  Set(schema.keys).isSubset(of: ["type", "properties", "required", "title", "description", "$schema"]),
                  let properties = schema["properties"]?.objectValue
            else {
                throw HTTPClientError.unsupportedInput
            }
            if let dialect = schema["$schema"], dialect != .string("https://json-schema.org/draft/2020-12/schema") {
                throw HTTPClientError.unsupportedInput
            }
            let required = schema["required"]?.arrayValue?.compactMap(\.stringValue)
            if let raw = schema["required"], required?.count != raw.arrayValue?.count || raw.arrayValue == nil {
                throw HTTPClientError.unsupportedInput
            }
            return .init(message: message, mode: .form, requestedSchema: .init(
                title: schema["title"]?.stringValue, description: schema["description"]?.stringValue,
                properties: properties, required: required
            ))
        }
    }

    let inputRequests: [String: Input]?
    let requestState: String?

    func responses(using handler: HTTPFormHandler?) async throws -> [String: Value] {
        var responses: [String: Value] = [:]
        for (key, request) in (inputRequests ?? [:]).sorted(by: { $0.key < $1.key }) {
            let form = try request.form()
            guard let handler else { throw HTTPClientError.inputUnavailable }
            let response = try await handler(form)
            try Task.checkCancellation()
            responses[key] = try HTTPProtocol.value(response)
        }
        return responses
    }
}

/// Discriminate before decoding content: input_required has no final tool content.
enum HTTPToolResult: Decodable, Sendable {
    case complete(CallTool.Result)
    case inputRequired(HTTPInputRequired)
    case task(HTTPTask)

    enum CodingKeys: String, CodingKey { case resultType }
    init(from decoder: Decoder) throws {
        let tag = try decoder.container(keyedBy: CodingKeys.self)
            .decodeIfPresent(String.self, forKey: .resultType)
        switch tag {
        case "complete", nil: self = try .complete(CallTool.Result(from: decoder))
        case "task": self = try .task(HTTPTask(from: decoder))
        case "input_required": self = try .inputRequired(HTTPInputRequired(from: decoder))
        default: throw HTTPClientError.invalidResponse
        }
    }
}

enum HTTPProtocol {
    static let version = "2026-07-28"
    static let versionKey = "io.modelcontextprotocol/protocolVersion"
    static let capabilitiesKey = "io.modelcontextprotocol/clientCapabilities"
    static let clientInfoKey = "io.modelcontextprotocol/clientInfo"
    static let subscriptionKey = "io.modelcontextprotocol/subscriptionId"

    static func value(_ value: some Encodable) throws -> Value {
        try JSONDecoder().decode(HTTPJSONValue.self, from: JSONEncoder().encode(value)).value
    }

    static func parameters(_ value: some Encodable) throws -> [String: Value] {
        guard case let .object(fields) = try self.value(value) else {
            throw HTTPClientError.invalidResponse
        }
        return fields
    }
}
