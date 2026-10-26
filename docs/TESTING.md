# Testing

How this repository is tested, and what has been ported from the web client's tests.

## Layers

| Layer | Where | Runs with |
|---|---|---|
| Generator | `Tools/PurlayGen/Tests` | `swift test` in `Tools/PurlayGen` |
| Contract types | `Packages/PurlayContract/Tests` | `swift test` — every schema is read from an example built out of itself and written back unchanged |
| Kit (transport, auth, realtime) | `Packages/PurlayKit/Tests`, `Packages/PurlayTestSupport/Tests` | `swift test` — against a scripted transport and a scripted socket |
| Contract tests | `Tests/ContractTests` | `scripts/contract-test` — the real client against a real server of the pinned version: the handshake, every read the contract lists, the socket (open, subscribe, live frames, send, replay after a drop, refused upgrades), and the sign-in as the application, end to end |
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
| `socket.test.ts` | `Tests/ContractTests` — `LiveSocketTests` | covered against the real server (the transport is `URLSession`'s, and a fake of it would test the fake) |
| `pending-store.ts` and the send cases of `engine.test.ts` | `OutboxStoreTests`, `SendCoordinatorTests` | ported: a send over the socket, over HTTP, with attachments, across a reconnect, kept across a relaunch, a channel that went away, and an id the server finds too old |
| `engine.test.ts` (frames, replay, refused subscriptions, routing) | `ChatStateTests`, `ChannelWindowTests`, `EngineTests` | ported by behaviour; the cache cases are the window's, since the app holds messages in a `ChannelWindow` and not in a query cache |
