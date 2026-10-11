import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// The 2026 HTTP binding's standard headers and schema-declared primitive mirrors.
enum HTTPRoutingHeaders {
    static func validate(_ schema: Value) throws {
        var names: Set<String> = []
        var unused: [String: String] = [:]
        try mirror(schema: schema, value: nil, reachable: false, usedNames: &names, headers: &unused)
    }

    static func apply(
        method: String,
        parameters: [String: Value],
        schema: Value?,
        to request: inout URLRequest
    ) throws {
        for key in (request.allHTTPHeaderFields ?? [:]).keys
            where key.lowercased() == "mcp-name" || key.lowercased().hasPrefix("mcp-param-") {
            request.setValue(nil, forHTTPHeaderField: key)
        }
        request.setValue(method, forHTTPHeaderField: "Mcp-Method")
        let name = parameters["name"] ?? parameters["uri"]
        if let name, case let .string(text) = name {
            request.setValue(encode(text), forHTTPHeaderField: "Mcp-Name")
        }
        if method == CallTool.name, let schema {
            var usedNames: Set<String> = []
            var headers: [String: String] = [:]
            try mirror(
                schema: schema,
                value: parameters["arguments"],
                reachable: false,
                usedNames: &usedNames,
                headers: &headers
            )
            for (name, value) in headers {
                request.setValue(value, forHTTPHeaderField: name)
            }
        }
    }

    static func encode(_ text: String) -> String {
        let safe = text.utf8.allSatisfy { $0 == 9 || (32 ... 126).contains($0) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines) == text
        let sentinel = text.hasPrefix("=?base64?") && text.hasSuffix("?=")
        return safe && trimmed && !sentinel ? text : "=?base64?\(Data(text.utf8).base64EncodedString())?="
    }

    private static func mirror(
        schema: Value, value: Value?, reachable: Bool,
        usedNames: inout Set<String>, headers: inout [String: String]
    ) throws {
        guard case let .object(fields) = schema else { return }
        if let annotation = fields["x-mcp-header"] {
            guard reachable, case let .string(name) = annotation, !name.isEmpty,
                  name.utf8.allSatisfy({ tokenBytes.contains($0) }),
                  usedNames.insert(name.lowercased()).inserted,
                  let type = fields["type"]?.stringValue,
                  ["string", "integer", "boolean"].contains(type) else {
                throw HTTPClientError.invalidHeaderAnnotation
            }
            if let value {
                let text: String
                switch (type, value) {
                case let ("string", .string(string)): text = string
                case let ("boolean", .bool(bool)): text = bool ? "true" : "false"
                case let ("integer", .int(integer)) where abs(Double(integer)) <= 9_007_199_254_740_991:
                    text = String(integer)
                default: throw HTTPClientError.invalidHeaderAnnotation
                }
                headers["Mcp-Param-\(name)"] = encode(text)
            }
        }
        for (key, child) in fields where key != "x-mcp-header" {
            if key == "properties", case let .object(properties) = child {
                for (property, definition) in properties {
                    try mirror(
                        schema: definition,
                        value: value?[httpField: property],
                        reachable: true,
                        usedNames: &usedNames,
                        headers: &headers
                    )
                }
            } else if !["default", "const", "enum", "examples"].contains(key) {
                try rejectHiddenAnnotations(child)
            }
        }
    }

    private static func rejectHiddenAnnotations(_ value: Value) throws {
        switch value {
        case let .object(fields):
            guard fields["x-mcp-header"] == nil else { throw HTTPClientError.invalidHeaderAnnotation }
            for child in fields.values {
                try rejectHiddenAnnotations(child)
            }
        case let .array(values):
            for child in values {
                try rejectHiddenAnnotations(child)
            }
        default: break
        }
    }

    private static let tokenBytes = Set("!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
        .utf8)
}
