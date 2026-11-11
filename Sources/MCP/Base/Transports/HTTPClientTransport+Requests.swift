import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

extension HTTPClientTransport {
    /// Sends data through an HTTP POST request
    public func send(_ data: Data) async throws {
        guard isConnected else {
            throw MCPError.internalError("Transport not connected")
        }

        if let authorizer {
            do {
                try authorizer.validateEndpointSecurity(for: endpoint)
            } catch {
                throw MCPError.internalError(
                    "Authorization flow failed: \(error.localizedDescription)"
                )
            }
        }

        if let authorizer {
            try? await authorizer.prepareAuthorization(for: endpoint, session: session)
        }

        var attempts = 0
        let operationKey = jsonRPCOperationKey(from: data)

        while true {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.addValue(
                "\(ContentType.json), \(ContentType.sse)",
                forHTTPHeaderField: HTTPHeaderName.accept
            )
            request.addValue(ContentType.json, forHTTPHeaderField: HTTPHeaderName.contentType)
            request.httpBody = data

            if let protocolVersion = protocolVersion {
                request.addValue(protocolVersion, forHTTPHeaderField: HTTPHeaderName.protocolVersion)
            }

            if let sessionID = sessionID {
                request.addValue(sessionID, forHTTPHeaderField: HTTPHeaderName.sessionID)
            }

            if let authValue = authorizer?.authorizationHeader(for: endpoint) {
                request.setValue(authValue, forHTTPHeaderField: HTTPHeaderName.authorization)
            }

            request = requestModifier(request)

            do {
                #if os(Linux)
                    let (responseData, response) = try await session.data(for: request)
                    try await processResponse(response: response, data: responseData)
                #else
                    let (responseStream, response) = try await session.bytes(for: request)
                    try await processResponse(response: response, stream: responseStream)
                #endif
                return
            } catch let authError as HTTPAuthenticationChallengeError {
                guard let authorizer, attempts < authorizer.maxAuthorizationAttempts else {
                    throw mapAuthenticationChallengeError(authError)
                }
                attempts += 1

                let handled: Bool
                do {
                    handled = try await authorizer.handleChallenge(
                        statusCode: authError.statusCode,
                        headers: authError.headers,
                        endpoint: endpoint,
                        operationKey: operationKey,
                        session: session
                    )
                } catch {
                    throw MCPError.internalError(
                        "Authorization flow failed: \(error.localizedDescription)")
                }

                if handled {
                    continue
                }

                throw mapAuthenticationChallengeError(authError)
            }
        }
    }

    #if os(Linux)
        private func processResponse(response: URLResponse, data: Data) async throws {
            guard let httpResponse = response as? HTTPURLResponse else {
                throw MCPError.internalError("Invalid HTTP response")
            }

            let contentType = httpResponse.value(forHTTPHeaderField: HTTPHeaderName.contentType) ?? ""

            if let newSessionID = httpResponse.value(forHTTPHeaderField: HTTPHeaderName.sessionID) {
                let wasSessionIDNil = (self.sessionID == nil)
                self.sessionID = newSessionID
                if wasSessionIDNil {
                    triggerInitialSessionIDSignal()
                }
                logger.debug("Session ID received", metadata: ["sessionID": "\(newSessionID)"])
            }

            try processHTTPResponse(httpResponse, contentType: contentType)
            guard case 200..<300 = httpResponse.statusCode else { return }

            if contentType.contains(ContentType.sse) {
                logger.warning("SSE responses aren't fully supported on Linux")
                messageContinuation.yield(data)
            } else if contentType.contains(ContentType.json) {
                logger.trace("Received JSON response", metadata: ["size": "\(data.count)"])
                messageContinuation.yield(data)
            } else {
                logger.warning("Unexpected content type: \(contentType)")
            }
        }
    #else
        private func processResponse(response: URLResponse, stream: URLSession.AsyncBytes)
            async throws
        {
            guard let httpResponse = response as? HTTPURLResponse else {
                throw MCPError.internalError("Invalid HTTP response")
            }

            let contentType = httpResponse.value(forHTTPHeaderField: HTTPHeaderName.contentType) ?? ""

            if let newSessionID = httpResponse.value(forHTTPHeaderField: HTTPHeaderName.sessionID) {
                let wasSessionIDNil = (self.sessionID == nil)
                self.sessionID = newSessionID
                if wasSessionIDNil {
                    triggerInitialSessionIDSignal()
                }
                logger.debug("Session ID received", metadata: ["sessionID": "\(newSessionID)"])
            }

            try processHTTPResponse(httpResponse, contentType: contentType)
            guard case 200..<300 = httpResponse.statusCode else { return }

            if contentType.contains(ContentType.sse) {
                logger.trace("Received SSE response, processing in streaming task")
                let hadData = try await self.processSSE(stream)

                if !hadData {
                    logger.debug("POST SSE stream closed without data, triggering GET reconnection")
                    self.activeGETSessionTask?.cancel()
                }
            } else if contentType.contains(ContentType.json) {
                var buffer = Data()
                for try await byte in stream {
                    buffer.append(byte)
                }
                logger.trace("Received JSON response", metadata: ["size": "\(buffer.count)"])
                messageContinuation.yield(buffer)
            } else {
                logger.warning("Unexpected content type: \(contentType)")
            }
        }
    #endif

    private func processHTTPResponse(_ response: HTTPURLResponse, contentType: String) throws {
        switch response.statusCode {
        case 200..<300:
            return

        case 400:
            throw MCPError.internalError("Bad request")

        case 401:
            throw HTTPAuthenticationChallengeError(
                statusCode: response.statusCode,
                headers: responseHeaders(from: response)
            )

        case 403:
            throw HTTPAuthenticationChallengeError(
                statusCode: response.statusCode,
                headers: responseHeaders(from: response)
            )

        case 404:
            if sessionID != nil {
                logger.warning("Session has expired")
                sessionID = nil
                throw MCPError.internalError("Session expired")
            }
            throw MCPError.internalError("Endpoint not found")

        case 405:
            if streaming {
                self.streamingTask?.cancel()
                throw MCPError.internalError("Server does not support streaming")
            }
            throw MCPError.internalError("Method not allowed")

        case 408:
            throw MCPError.internalError("Request timeout")

        case 429:
            throw MCPError.internalError("Too many requests")

        case 500..<600:
            throw MCPError.internalError("Server error: \(response.statusCode)")

        default:
            throw MCPError.internalError(
                "Unexpected HTTP response: \(response.statusCode) (\(contentType))")
        }
    }

    private func mapAuthenticationChallengeError(_ error: HTTPAuthenticationChallengeError) -> MCPError {
        switch error.statusCode {
        case 401:
            return MCPError.internalError("Authentication required")
        case 403:
            return MCPError.internalError("Access forbidden")
        default:
            return MCPError.internalError("HTTP authorization error: \(error.statusCode)")
        }
    }

    private func responseHeaders(from response: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let key = key as? String, let value = value as? String else { continue }
            headers[key] = value
        }
        return headers
    }

    private func jsonRPCOperationKey(from data: Data) -> String? {
        guard
            let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let method = jsonObject["method"] as? String
        else {
            return nil
        }

        let normalized = method.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

}
