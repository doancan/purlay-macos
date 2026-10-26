# Testing

How this repository is tested, and what has been ported from the web client's tests.

## Layers

| Layer | Where | Runs with |
|---|---|---|
| Generator | `Tools/PurlayGen/Tests` | `swift test` in `Tools/PurlayGen` |
| Contract types | `Packages/PurlayContract/Tests` | `swift test` — every schema is read from an example built out of itself and written back unchanged |
| Kit (transport, auth, realtime) | `Packages/PurlayKit/Tests`, `Packages/PurlayTestSupport/Tests` | `swift test` — against a scripted transport and a scripted socket |
| Whole | `scripts/verify` | everything above, the architecture rules, the build of the app in both configurations |

Tests are written to the behaviour a document states and the contract's own fixtures, not to the implementation. Faults are
injected at the seams (`HTTPTransport`, `OpenSocket`, the clock and the timers), never by replacing the code under test.

## What is held to the server's own fixtures

The pinned bundle (`Contract/bundle/fixtures`) carries what a second implementation is held to. Message ids (what is made,
what is refused, the plausibility window) are checked in `RealtimePrimitivesTests`. The markdown conformance corpus is
checked when the renderer exists (M3-2).

## Ports of the web client's tests

The web client's tests are the test plan for the realtime engine. Each is ported case by case, by name. A file in this table
that is not yet ported says so.

| Web (`apps/web/src/realtime/`) | Here | State |
|---|---|---|
| `backoff.test.ts` | `RealtimePrimitivesTests` — `BackoffTests` | ported |
| `cursors.test.ts` | `RealtimePrimitivesTests` — `CursorsTests` | ported |
| `server-clock.test.ts` | `RealtimePrimitivesTests` — `ServerClockTests` | ported |
| `connection.test.ts` | `ConnectionTests`, `ConnectionNetworkTests`, `ConnectionReplayTests` | ported (every case) |
| `socket.test.ts` | — | with the URLSession socket transport (M2-1) |
| `pending-store.test.ts` | — | with the outbox (M2-4) |
| `engine.test.ts` | — | with the engine (M2-3 to M2-5) |
