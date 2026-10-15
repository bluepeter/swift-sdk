# Cumbersome HTTP client extension

This unofficial fork starts at official `modelcontextprotocol/swift-sdk` 0.12.1,
commit `a0ae212ebf6eab5f754c3129608bc5557637e605`. The existing `Client`,
`HTTPClientTransport`, protocol version constants, server APIs, and older
elicitation callbacks are unchanged. The public repository is
https://github.com/bluepeter/swift-sdk.

`HTTPClient` adds the 2026-07-28 HTTP client path needed by Cumbersome:

- Discovery, per-request metadata, routing headers, JSON and SSE responses.
- Redirects use URLSession's normal handling, matching the legacy transport.
  App Transport Security remains configured by the host app.
- A discovery probe can select the existing legacy initialization path.
  HTTP error responses retain their status even when rejected before JSON-RPC
  dispatch with a generic ID. Successful HTTP responses retain the existing
  JSON-RPC ID checks.
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
- Form elicitation and the released 2026-07-28 Tasks extension are supported.
  Tasks is advertised per tool call only when discovery declares it and the
  caller supplies a task handler. The host owns persistence, polling, deadlines,
  and recovery through `getTask`, `updateTask`, and `cancelTask`. A cancellation
  acknowledgment does not confirm the final outcome. Lifecycle calls carry the
  task ID in both parameters and `Mcp-Name`, and never replay the original tool.
- URL elicitation, sampling, roots, legacy experimental Tasks, and full modern
  server support are outside this extension. Reusing the
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
[subscriptions](https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/subscriptions),
and [Tasks](https://modelcontextprotocol.io/extensions/tasks/overview).

## Maintenance and checks

Use this additive API until an upstream release supports and verifies the same
flow. Do not update `Version.latest` to imply that the unchanged SDK server and
legacy client implement 2026. Do not apply build-time patches to package checkouts.

Run `swift build --disable-sandbox` and `swift test --disable-sandbox` on macOS.
The original HTTP transport suite retains its 52 tests, split into focused files;
its URLProtocol task closure is explicitly Sendable for the current Swift compiler.
New tests cover form/state round trips, fallback after a captured Kagi/FastMCP
HTTP rejection, negotiated headers on stateless legacy SSE connections, auth
failures (including generic error IDs and advertised older protocols), tool
errors without fallback or replay, response ID correlation, bounded response
buffering, progress, concurrency, cancellation,
retry limits, and header handling. Loopback HTTP tests
cover 307 and 308 redirects through discovery and tool calls, preserving POST
bodies and matching URLSession's credential handling. Subscription tests
cover graceful and abrupt closure, bounded retry and rearming, stable stream
budget renewal, permanent refusal, initial listen failure, and cancellation
during backoff. Cumbersome's `Tests/MCPBaseline` also exercises old Everything,
a 2026 loopback wire fixture, and upstream 2026 Everything with actual socket
drops and process restarts through the app's cached chat executor.
Tasks checks cover opt-in capability negotiation, lifecycle routing, typed terminal
results, required null TTL persistence, and input forms with the JSON Schema
2020-12 dialect declaration. Cumbersome also verifies task completion and saved
handle recovery with form input against the pinned upstream 2026 Everything.
These checks do not establish universal conformance or third-party compatibility.

On 2026-10-15, Cumbersome's `MCPClientService` connected to the authenticated
Kagi endpoint using this working SDK, negotiated 2025-11-25, discovered
`kagi_search_fetch` and `kagi_extract`, and refreshed the tool list. A subsequent
live check through the same app client executed one search and two extractions:
search returned the official Swift documentation, and extraction returned the
requested public example page content. The app's legacy/modern fixture baseline
and official 2026 Everything checks also passed.
