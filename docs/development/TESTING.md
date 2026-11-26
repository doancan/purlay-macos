# Testing

How this repository is tested, and where the tests of what it uses live. The model, the transport and the realtime engine are
[`purlay-swift`](https://github.com/purlay/purlay-swift)'s, so most behaviour tests are there; this repository tests what it draws and how it is built.

## Layers

| Layer | Where | Runs with |
|---|---|---|
| Contract, Kit (state, transport, auth, realtime, outbox, markdown), tokens | `purlay-swift` — `Tests/PurlayContractTests`, `Tests/PurlayKitTests`, `Tests/PurlayTokensTests`, and the live-server `ContractTests` | `scripts/verify` there; this repository pins a released version |
| Views | `Packages/PurlayUI/Tests/PurlayUITests`: `ComposerStateTests`, `FloatingPanelTests`, `NativePaletteTests`, `PurlayUITests` (the sentences a person reads), `ReactionEmojiTests`, `TokenBindingTests` | `scripts/verify test` |
| Screens | `Packages/PurlayUI/Tests/PurlayUITests/SnapshotTests.swift` | Issues, Updates, the sign-in page, the profile editor, a workspace without chat, a channel that could not be loaded and the signed-in window drawn from state, light and dark, with no server, keychain or click. They run where `PURLAY_SNAPSHOT_DIR` names a folder; `scripts/verify test` sets it (as `TEST_RUNNER_PURLAY_SNAPSHOT_DIR`) to a temporary folder and fails if no screen was drawn. To look at the pictures: `TEST_RUNNER_PURLAY_SNAPSHOT_DIR=/tmp/screens xcodebuild -scheme PurlayUI -destination 'platform=macOS' test` in `Packages/PurlayUI` |
| Languages | `scripts/localize --check` | every string of `Localizable.xcstrings` has a final Turkish value with the same format specifiers |
| The build | `scripts/verify app` (Debug), `scripts/verify` (Debug and Release) | the app builds; App Transport Security is strict in Release and relaxed for localhost in Debug only; the sandbox entitlements, declared and signed, are the allowlist and nothing else |
| Architecture rules | `scripts/enforcement`, and `scripts/enforcement --demo` | each rule is also run against a copy of the tree with its violation planted, and must refuse it |
| Secrets | `scripts/verify security` | the whole git history, with gitleaks |

Tests are written to the behaviour a document states and the contract's own fixtures, not to the implementation. Faults are
injected at the seams (`HTTPTransport`, `OpenSocket`, the clock and the timers), never by replacing the code under test.
What no test here reaches — the notification and Dock-badge permissions, the login item, Sparkle's update, signing and notarization —
is checked by hand on a signed build, and the release workflow is the only place the signed path runs ([`tech-debt.md`](../architecture/tech-debt.md) TD-004).

## What is held to the server's own fixtures

The pinned bundle (`Contract/bundle/fixtures` in `purlay-swift`, fetched by its `scripts/contract`) carries what a second implementation is held to. Message ids (what is made,
what is refused, the plausibility window) are checked in `RealtimePrimitivesTests`. The markdown conformance corpus is checked by
`MarkdownCorpusTests`, with its known divergences listed in `MarkdownDivergences`.

## Ports of the web client's tests

The web client's tests are the test plan for the realtime engine. Each is ported case by case, by name. All of these are in
`purlay-swift`, under `Tests/PurlayKitTests` unless said otherwise. A file in this table that is not yet ported says so.

| Web (`apps/web/src/realtime/`) | `purlay-swift` | State |
|---|---|---|
| `backoff.test.ts` | `RealtimePrimitivesTests` — `BackoffTests` | ported |
| `cursors.test.ts` | `RealtimePrimitivesTests` — `CursorsTests` | ported |
| `server-clock.test.ts` | `RealtimePrimitivesTests` — `ServerClockTests` | ported |
| `connection.test.ts` | `ConnectionTests`, `ConnectionNetworkTests`, `ConnectionReplayTests` | ported (every case) |
| `socket.test.ts` | `ContractTests/Tests/LiveSocketTests` | covered against the real server (the transport is `URLSession`'s, and a fake of it would test the fake) |
| `pending-store.ts` and the send cases of `engine.test.ts` | `OutboxStoreTests`, `SendCoordinatorTests` | ported: a send over the socket, over HTTP, with attachments, across a reconnect, kept across a relaunch, a channel that went away, and an id the server finds too old |
| `engine.test.ts` (frames, replay, refused subscriptions, routing) | `ChatStateTests`, `ChannelWindowTests`, `EngineTests` | ported by behaviour; the cache cases are the window's, since the app holds messages in a `ChannelWindow` and not in a query cache |
