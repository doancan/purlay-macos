# Product vision: Purlay for macOS

> Last updated: 2026-11-26 · Owner: maintainer (`@doancan`) · Written from the repository's README, changelog and code; where a fact is not in them it is an open question in [requirements.md](requirements.md).

## Problem

People on a team who live in conversations, threads and notifications want that to feel like a Mac app: native windows, the keyboard,
the system's notifications and quiet, and no browser tab to lose. A web client in a tab does none of that well.

## Users

- **Primary:** a member of a team on the hosted Purlay service (purlay.app), on an Apple Silicon Mac, signed in for days at a time.
- **Secondary:** workspace owners and administrators, who also reach administration pages through the app (they open in the browser).

## Job to be done

When my team's conversation is moving and I am working in other windows, I want the Mac to tell me what needs me and let me answer
without leaving my flow, so that I neither miss what matters nor am pulled out of what I am doing.

## Value over the alternative

- A native client (SwiftUI, Liquid Glass, system toolbar and sidebar), not a web page in a frame.
- Keyboard-first: a palette, search, menus for every action, and shortcuts that the app lists.
- Calm by design: Deep Work, a focused Inbox, notices that never show what was said, and an idle cost that a test holds near zero.
- Safe by construction: no password in the app, the system browser for sign-in, the sandbox, signed and notarized builds, signed updates.

## Platforms

macOS 26 or later on Apple Silicon (arm64); built with the macOS 27 SDK ([ADR 0003](../decisions/0003-platform-floor-and-architecture.md)).
It is a client of the Purlay server and does not host one. The same engine serves
[`purlay-ios`](https://github.com/purlay/purlay-ios) through [`purlay-swift`](https://github.com/purlay/purlay-swift).

## Success metrics

None is recorded in the repository (Q-004); the measurable bars it does hold are the non-functional requirements in [requirements.md](requirements.md).

## Where it is

Released: 0.3.0 (2026-11-24), with fixes waiting under `Unreleased` in the changelog. Functional scope: FR-001 to FR-024.

## Non-goals

- Hosting or administering a server: the app opens server and workspace administration in the browser.
- Intel Macs and macOS before 26.
- Signing in to a server other than purlay.app in release builds (Q-003).
- A second design for systems without Liquid Glass.

## Constraints

Swift 6 with strict concurrency; AGPL-3.0 with a contributor agreement; Developer ID signing and notarization; the server owns the
contract, and this client never writes a wire type by hand ([ADR 0002](../decisions/0002-contract-tokens-and-engine-from-purlay-swift.md)).
