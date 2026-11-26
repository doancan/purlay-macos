# Purlay for macOS

The native macOS client for [Purlay](https://github.com/purlay/purlay), team chat today and the modules that follow it: SwiftUI with AppKit
where it earns its place, drawn in Liquid Glass, for Apple Silicon Macs on macOS 26 or later. It is a client: it hosts no server, and the
wire contract, the design tokens and the client engine come from [`purlay-swift`](https://github.com/purlay/purlay-swift), shared with
[`purlay-ios`](https://github.com/purlay/purlay-ios). Released as signed, notarized builds that update themselves with Sparkle.

## Current status

- **Stage:** production. 0.3.0 was released on 2026-11-24; two fixes wait under `Unreleased` in `CHANGELOG.md`.
- **Working:** FR-001 to FR-024 ([`product/requirements.md`](product/requirements.md)): sign-in through the system browser, channels, threads,
  reactions, realtime with replay and a durable outbox, Inbox, Open Topics, Deep Work, Saved and Drafts, Search, Scheduled, Reminders, Issues
  and Updates, sidebar groups, conversation windows, app links, Settings and administration, Dock badge and notices, Sparkle updates, English and Turkish.
- **Not done:** followed threads (FR-025, blocked: the contract has no endpoint); PDFs open in Quick Look's own viewer.
- **Baseline at adoption** (`main` at `b7b7abb`, 2026-11-26): `scripts/verify`, every lane with the Release build, exits 0.
- **Not verified here:** the signed release path (Developer ID, notarization, Sparkle's update) and the notification, Dock-badge and login-item
  permissions. They need the release secrets or a signed build ([TD-004](architecture/tech-debt.md)).
- **Known debts:** six, in [`architecture/tech-debt.md`](architecture/tech-debt.md). **Open questions:** five (Q-001 to Q-005) in the requirements.

## Current constraints

- One verify entry point, `make verify`, whose lanes live in `scripts/verify`; a secret in the history fails the check — [ADR 0001](decisions/0001-verify-entry-point-and-secret-scan.md)
- The contract, tokens and client engine come only from `purlay-swift`, pinned by version in two files that must agree; no wire type is written by hand — [ADR 0002](decisions/0002-contract-tokens-and-engine-from-purlay-swift.md)
- macOS 26 floor, built with the macOS 27 SDK, Apple Silicon only; one floor number everywhere — [ADR 0003](decisions/0003-platform-floor-and-architecture.md)
- No dependency beyond Sparkle and `purlay-swift`; `PurlayUI` opens no connection; only `App/Updates` imports Sparkle; production code cannot trap — enforced by `scripts/enforcement` ([conventions](architecture/conventions.md))
- The sandbox entitlements are an allowlist; App Transport Security is strict in Release — checked by `scripts/verify app`

## Next steps

1. TD-002: make the colour rule real in `scripts/enforcement`, so that tokens are the only source of colour (`NativePalette` allowed).
2. FR-006 / Q-005: give Open Topics a test.
3. FR-025: followed threads, when the contract carries an endpoint.

## Quick start

**Requirements:** Xcode 27 or later, on an Apple Silicon Mac (macOS 26 or later).

```sh
make setup      # XcodeGen and gitleaks at their pinned versions
xcodegen generate
xcodebuild -project Purlay.xcodeproj -scheme Purlay -configuration Debug -destination 'platform=macOS,arch=arm64' build
```

`PURLAY_DEV_SERVER` points a Debug build at another server (plain HTTP to localhost is allowed in Debug only); with `PURLAY_DEV_SESSION` it seeds a session. See [`development/DEVELOPMENT.md`](development/DEVELOPMENT.md).

## Verification

```sh
make verify   # rules, format and tests, the Debug app: what a pull request needs
```

A change is not done until this is green. Also: `make verify-security` (the history scanned for secrets, required in CI) and
`make verify-all` (every lane, with the Release build, as a release runs it). The repositories are private, so the shared-files check
needs `GITHUB_TOKEN="$(gh auth token)"`. CI runs the same lanes side by side.

## Project structure

```
App/                      # the shell: scenes, commands, system adapters; App/Updates is Sparkle's only home
Packages/PurlayUI/        # every view; opens no connection
Config/ project.yml       # build settings, and the project XcodeGen generates (never committed)
scripts/                  # verify (the lanes), enforcement, localize, release-notes, sign-release, install-*
docs/                     # this documentation
```

## Docs map

| Document | Read when |
|---|---|
| [architecture/overview.md](architecture/overview.md) | adding or moving a module, changing a data flow |
| [architecture/conventions.md](architecture/conventions.md) | before every code change |
| [architecture/tech-debt.md](architecture/tech-debt.md) | taking on or paying a debt |
| [decisions/](decisions/) | asking why something is as it is; before an architecture change |
| [product/vision.md](product/vision.md), [product/requirements.md](product/requirements.md) | changing behaviour; the FRs, NFRs and open questions |
| [product/features/client-behaviour.md](product/features/client-behaviour.md) | the details of a behaviour that is not obvious from the screen |
| [development/DEVELOPMENT.md](development/DEVELOPMENT.md) | setting up, signing, updates, languages |
| [development/TESTING.md](development/TESTING.md) | what is tested where, and what is held to the server's fixtures |
| [runbooks/release.md](runbooks/release.md), [runbooks/bump-shared-package.md](runbooks/bump-shared-package.md) | cutting a release; moving to a new `purlay-swift` |

## Recent decisions

- [0003 — macOS 26 floor, macOS 27 SDK, Apple Silicon only](decisions/0003-platform-floor-and-architecture.md)
- [0002 — contract, tokens and engine from `purlay-swift`](decisions/0002-contract-tokens-and-engine-from-purlay-swift.md)
- [0001 — one verify entry point, and a secret scan](decisions/0001-verify-entry-point-and-secret-scan.md)

## Working rule

In every change: read the relevant document, make the change, update the documents in the same change, write an ADR when a decision
was taken, then run `make verify`.
