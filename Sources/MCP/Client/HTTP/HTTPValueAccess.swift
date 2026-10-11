import Foundation

/// Keep wire inspection internal to the HTTP implementation.
extension Value {
    subscript(httpField key: String) -> Value? {
        guard case let .object(fields) = self else { return nil }
        return fields[key]
    }
}

/// MCP Value's legacy decoder recognizes data URLs. HTTP continuation tokens and
/// user answers are JSON strings, and must never be decoded as binary data.
struct HTTPJSONValue: Decodable {
    let value: Value
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = .null
        } else if let string = try? container.decode(String.self) {
            value = .string(string)
        } else if let bool = try? container.decode(Bool.self) {
            value = .bool(bool)
        } else if let integer = try? container.decode(Int.self) {
            value = .int(integer)
        } else if let number = try? container.decode(Double.self) {
            value = .double(number)
        } else if let array = try? container.decode([HTTPJSONValue].self) {
            value = .array(array.map(\.value))
        } else {
            value = try .object(container.decode([String: HTTPJSONValue].self).mapValues(\.value))
        }
    }
}
