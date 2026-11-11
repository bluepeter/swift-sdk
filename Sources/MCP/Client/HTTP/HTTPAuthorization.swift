#if canImport(EventSource)
    import Foundation

    /// An OAuth token is bound to the configured resource, including its path.
    /// Return redirects to the caller instead of forwarding tokens or replaying
    /// tool bodies at another destination. The host can explicitly reconfigure.
    final class HTTPAuthorizationRedirectDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _: URLSession, task _: URLSessionTask,
            willPerformHTTPRedirection _: HTTPURLResponse, newRequest _: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    struct HTTPAuthorizationChallenge: Error {
        let status: Int
        let headers: [String: String]

        init(response: HTTPURLResponse) {
            status = response.statusCode
            headers = response.allHeaderFields.reduce(into: [:]) { result, entry in
                guard let name = entry.key as? String, let value = entry.value as? String else { return }
                result[name] = value
            }
        }

        var responseError: HTTPClientError {
            .response(status: status, code: nil, message: nil, data: nil)
        }
    }
#endif
