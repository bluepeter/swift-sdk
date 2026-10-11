@preconcurrency import Foundation
import Logging
import Testing

@testable import MCP

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

#if swift(>=6.1)
@Suite("HTTP Client Transport Tests", .serialized)
struct HTTPClientTransportTests {
    let testEndpoint = URL(string: "https://localhost:8080/test")!
}
#endif
