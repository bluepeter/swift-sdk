#if canImport(EventSource)
    import Foundation
    @testable import MCP

    final class HTTPTestAuthorizer: HTTPClientAuthorizer, @unchecked Sendable {
        let maxAuthorizationAttempts: Int
        private let handlesChallenges: Bool
        private let lock = NSLock()
        private var storedToken: String?
        private var methods: [String?] = []
        private var statuses: [Int] = []
        private var headers: [[String: String]] = []
        private var preparations = 0

        init(token: String? = nil, maxAuthorizationAttempts: Int = 3, handlesChallenges: Bool = true) {
            storedToken = token
            self.maxAuthorizationAttempts = maxAuthorizationAttempts
            self.handlesChallenges = handlesChallenges
        }

        var token: String? {
            get { lock.withLock { storedToken } }
            set { lock.withLock { storedToken = newValue } }
        }

        var challengeMethods: [String?] { lock.withLock { methods } }
        var challengeStatuses: [Int] { lock.withLock { statuses } }
        var challengeHeaders: [[String: String]] { lock.withLock { headers } }
        var prepareCount: Int { lock.withLock { preparations } }

        func validateEndpointSecurity(for endpoint: URL) throws {
            guard endpoint.scheme == "https" || endpoint.host == "127.0.0.1" else {
                throw HTTPClientError.invalidResponse
            }
        }

        func authorizationHeader(for endpoint: URL) -> String? {
            token.map { "Bearer \($0)" }
        }

        func prepareAuthorization(for endpoint: URL, session: URLSession) async throws {
            lock.withLock { preparations += 1 }
        }

        func handleChallenge(
            statusCode: Int, headers: [String: String], endpoint: URL, operationKey: String?, session: URLSession
        ) async throws -> Bool {
            lock.withLock {
                methods.append(operationKey)
                statuses.append(statusCode)
                self.headers.append(headers)
                if handlesChallenges { storedToken = "accepted" }
            }
            return handlesChallenges
        }
    }
#endif
