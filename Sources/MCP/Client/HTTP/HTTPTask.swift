import Foundation

/// Released 2026-07-28 Tasks extension. Hosts own persistence and observation.
public struct HTTPTask: Codable, Sendable, Equatable {
    public static let extensionIdentifier = "io.modelcontextprotocol/tasks"

    public enum Status: String, Codable, Sendable {
        case working, inputRequired = "input_required", completed, failed, cancelled

        public var isTerminal: Bool {
            self == .completed || self == .failed || self == .cancelled
        }
    }

    public let taskId: String
    public let status: Status
    public let createdAt: String
    public let lastUpdatedAt: String
    public let ttlMs: Int?
    public let pollIntervalMs: Int?
    public let statusMessage: String?

    enum CodingKeys: String, CodingKey {
        case taskId, status, createdAt, lastUpdatedAt, ttlMs, pollIntervalMs, statusMessage
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        taskId = try fields.decode(String.self, forKey: .taskId)
        status = try fields.decode(Status.self, forKey: .status)
        createdAt = try fields.decode(String.self, forKey: .createdAt)
        lastUpdatedAt = try fields.decode(String.self, forKey: .lastUpdatedAt)
        ttlMs = try fields.decode(Int?.self, forKey: .ttlMs)
        pollIntervalMs = try fields.decodeIfPresent(Int.self, forKey: .pollIntervalMs)
        statusMessage = try fields.decodeIfPresent(String.self, forKey: .statusMessage)
        guard !taskId.isEmpty, taskId.utf8.count <= 8192,
              createdAt.utf8.count <= 64, lastUpdatedAt.utf8.count <= 64,
              (statusMessage?.utf8.count ?? 0) <= 16 * 1024,
              Self.date(createdAt) != nil, Self.date(lastUpdatedAt) != nil,
              ttlMs.map({ $0 >= 0 }) ?? true, pollIntervalMs.map({ $0 >= 0 }) ?? true else {
            throw HTTPClientError.invalidResponse
        }
    }

    public var expirationDate: Date? {
        guard let ttlMs, let created = Self.date(createdAt) else { return nil }
        return created.addingTimeInterval(Double(ttlMs) / 1000)
    }

    public func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(taskId, forKey: .taskId)
        try fields.encode(status, forKey: .status)
        try fields.encode(createdAt, forKey: .createdAt)
        try fields.encode(lastUpdatedAt, forKey: .lastUpdatedAt)
        // The released schema requires the key, with null meaning unlimited.
        try fields.encode(ttlMs, forKey: .ttlMs)
        try fields.encodeIfPresent(pollIntervalMs, forKey: .pollIntervalMs)
        try fields.encodeIfPresent(statusMessage, forKey: .statusMessage)
    }

    private static func date(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

public typealias HTTPTaskHandler = @Sendable (HTTPTask) async throws -> CallTool.Result

/// Detailed status returned by tasks/get. Creation responses need not contain
/// the final result or pending input, even when their status already names it.
public struct HTTPTaskState: Decodable, Sendable {
    public let task: HTTPTask
    public let result: CallTool.Result?
    public let error: HTTPTaskFailure?
    private let input: HTTPInputRequired?

    enum CodingKeys: String, CodingKey { case resultType, result, error }

    public init(from decoder: Decoder) throws {
        task = try HTTPTask(from: decoder)
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        guard try fields.decode(String.self, forKey: .resultType) == "complete" else {
            throw HTTPClientError.invalidResponse
        }
        result = task.status == .completed ? try fields.decode(CallTool.Result.self, forKey: .result) : nil
        error = task.status == .failed ? try fields.decode(HTTPTaskFailure.self, forKey: .error) : nil
        input = task.status == .inputRequired ? try HTTPInputRequired(from: decoder) : nil
        if task.status == .inputRequired, input?.inputRequests?.isEmpty != false {
            throw HTTPClientError.invalidResponse
        }
    }

    public func inputResponses(using handler: HTTPFormHandler?) async throws -> [String: Value] {
        guard let input else { throw HTTPClientError.invalidResponse }
        return try await input.responses(using: handler)
    }
}

/// Preserve the JSON RPC error instead of interpreting or logging server text.
public struct HTTPTaskFailure: Decodable, Sendable {
    public let code: Int
    public let message: String
    public let data: Value?

    enum CodingKeys: String, CodingKey { case code, message, data }
    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        code = try fields.decode(Int.self, forKey: .code)
        message = try fields.decode(String.self, forKey: .message)
        data = try fields.decodeIfPresent(HTTPJSONValue.self, forKey: .data)?.value
    }
}
