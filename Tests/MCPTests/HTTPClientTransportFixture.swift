@preconcurrency import Foundation
import Logging
import Testing

@testable import MCP

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

#if swift(>=6.1)
// MARK: - Test trait

/// A test trait that automatically manages the mock URL protocol handler for HTTP client transport tests.
struct HTTPClientTransportTestSetupTrait: TestTrait, TestScoping {
    func provideScope(
        for test: Test, testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        // Clear handler before test
        await MockURLProtocol.requestHandlerStorage.clearHandler()

        // Execute the test
        try await function()

        // Clear handler after test
        await MockURLProtocol.requestHandlerStorage.clearHandler()
    }
}

extension Trait where Self == HTTPClientTransportTestSetupTrait {
    static var httpClientTransportSetup: Self { Self() }
}

// MARK: - Mock Handler Registry Actor

actor RequestHandlerStorage {
    var requestHandler:
        (@Sendable (URLRequest) async throws -> (HTTPURLResponse, Data))?
    private var callCounts: [URL: Int] = [:]

    func setHandler(
        _ handler: @Sendable @escaping (URLRequest) async throws -> (HTTPURLResponse, Data)
    ) {
        requestHandler = handler
    }

    func clearHandler() {
        requestHandler = nil
        callCounts = [:]
    }

    func executeHandler(for request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        guard let handler = requestHandler else {
            throw NSError(
                domain: "MockURLProtocolError", code: 0,
                userInfo: [
                    NSLocalizedDescriptionKey: "No request handler set"
                ])
        }
        if let url = request.url {
            callCounts[url, default: 0] += 1
        }
        return try await handler(request)
    }

    func callCount(for url: URL) -> Int {
        callCounts[url, default: 0]
    }
}

// MARK: - Helper Methods

extension URLRequest {
    func readBody() -> Data? {
        if let httpBodyData = self.httpBody {
            return httpBodyData
        }

        guard let bodyStream = self.httpBodyStream else { return nil }
        bodyStream.open()
        defer { bodyStream.close() }

        let bufferSize: Int = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var data = Data()
        while bodyStream.hasBytesAvailable {
            let bytesRead = bodyStream.read(buffer, maxLength: bufferSize)
            data.append(buffer, count: bytesRead)
        }
        return data
    }
}

// MARK: - Mock URL Protocol

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    static let requestHandlerStorage = RequestHandlerStorage()

    static func setHandler(
        _ handler: @Sendable @escaping (URLRequest) async throws -> (HTTPURLResponse, Data)
    ) async {
        await requestHandlerStorage.setHandler { request in
            try await handler(request)
        }
    }

    func executeHandler(for request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        return try await Self.requestHandlerStorage.executeHandler(for: request)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        Task { @Sendable [self] in
            do {
                let (response, data) = try await self.executeHandler(for: request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {}

    static func verifyCallCounts(
        _ expected: [URL: Int],
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        for (url, expectedCount) in expected {
            let actual = await requestHandlerStorage.callCount(for: url)
            #expect(
                actual == expectedCount,
                "Expected \(expectedCount) call(s) to \(url.lastPathComponent), got \(actual)",
                sourceLocation: sourceLocation
            )
        }
    }
}

#endif
