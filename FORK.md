# Cumbersome HTTP client extension

This unofficial fork starts at official `modelcontextprotocol/swift-sdk` 0.12.1,
commit `a0ae212ebf6eab5f754c3129608bc5557637e605`. The existing `Client`,
`HTTPClientTransport`, protocol version constants, server APIs, and older
elicitation callbacks are unchanged. The public repository is
https://github.com/bluepeter/swift-sdk.

`HTTPClient` adds the 2026-07-28 HTTP client path needed by Cumbersome:

- Discovery, per-request metadata, routing headers, JSON and SSE responses.
- A discovery probe can select the existing legacy initialization path.
  Authentication failures and recognized modern protocol errors do not silently
  downgrade. Existing servers still receive an extra discovery probe.
- Tool calls own their form handler, opaque continuation state, retries, and
  cancellation. Retries use fresh IDs. Answers are never synthesized.
- Tool change subscriptions wait for acknowledgment. Stream closure does not
  replay writes or trigger an unlimited reconnect loop; explicit reconnect
  restores the subscription.
- Only form elicitation is advertised. URL elicitation, sampling, roots, Tasks,
  and full modern server support are outside this extension. Reusing the
  existing form value types does not enable older elicitation callbacks. Those
  callbacks receive a method-not-found error explaining the supported input/retry
  flow, without advertising callback support. The public
  `HTTPClient.formElicitationProtocolVersion` lets hosts describe that requirement.
- Unsupported URL input, other input methods, missing form context, validation
  limits, and transport errors remain distinct typed failures for host UI.
- Responses, individual SSE frames, and queued response bytes are bounded at
  16 MiB each. Input rounds are
  bounded at 16 by default. Callers own request deadlines and input UI policy.
- Supplied `inputSchema` overrides the last observed tool definition, allowing
  callers with atomic discovery caches to mirror headers from their own snapshot.

Sources: [2026 HTTP transport](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http),
[MRTR](https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/mrtr),
and [elicitation](https://modelcontextprotocol.io/specification/2026-07-28/client/elicitation).

## Maintenance and checks

Use this additive API until an upstream release supports and verifies the same
flow. Do not update `Version.latest` to imply that the unchanged SDK server and
legacy client implement 2026. Do not apply build-time patches to package checkouts.

Run `swift build --disable-sandbox` and `swift test --disable-sandbox` on macOS.
The original HTTP transport suite retains its 52 tests, split into focused files;
its URLProtocol task closure is explicitly Sendable for the current Swift compiler.
New tests cover form/state round trips, fallback, auth failures (including errors
advertising an older supported protocol), bounded response buffering, progress,
concurrency, cancellation, retry limits, and header handling. Cumbersome's
`Tests/MCPBaseline` also exercises old Everything and a 2026 loopback wire fixture.
These checks do not establish universal conformance or third-party compatibility.
