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
- Tool change subscriptions wait for acknowledgment. A dropped or completed
  stream gets at most three automatic replacements, with 1, 2, and 4 second
  delays. A stream acknowledged for at least 30 seconds resets that budget.
  Refused filters and permanent protocol/authentication errors stop recovery.
  Explicit disconnect is terminal, and tool calls are never replayed.
- Hosts use `onToolSubscriptionRestored` to refresh tools after a replacement
  stream is acknowledged, because notifications lost during an outage cannot
  be replayed. `recoverToolSubscription` rearms an exhausted cycle on foreground
  or tool use, coalescing with any active listen or retry. It does not reconnect
  a deliberately disconnected client or change the legacy transport.
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
[elicitation](https://modelcontextprotocol.io/specification/2026-07-28/client/elicitation),
and [subscriptions](https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/subscriptions).

## Maintenance and checks

Use this additive API until an upstream release supports and verifies the same
flow. Do not update `Version.latest` to imply that the unchanged SDK server and
legacy client implement 2026. Do not apply build-time patches to package checkouts.

Run `swift build --disable-sandbox` and `swift test --disable-sandbox` on macOS.
The original HTTP transport suite retains its 52 tests, split into focused files;
its URLProtocol task closure is explicitly Sendable for the current Swift compiler.
New tests cover form/state round trips, fallback, auth failures (including errors
advertising an older supported protocol), bounded response buffering, progress,
concurrency, cancellation, retry limits, and header handling. Subscription tests
cover graceful and abrupt closure, bounded retry and rearming, stable stream
budget renewal, permanent refusal, initial listen failure, and cancellation
during backoff. Cumbersome's `Tests/MCPBaseline` also exercises old Everything,
a 2026 loopback wire fixture, and upstream 2026 Everything with actual socket
drops and process restarts through the app's cached chat executor.
These checks do not establish universal conformance or third-party compatibility.
