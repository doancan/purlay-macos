# 0002. The contract, tokens and client engine come from `purlay-swift`

Status: accepted (retroactive record of purlay/purlay-macos#9, 2026-11-25).

**Context.** About 36,000 lines of tested Swift (wire types, sign-in, transport, realtime, outbox, tokens) lived in this
repository's packages, none of it AppKit-dependent, and a second Apple app, [`purlay-ios`](https://github.com/purlay/purlay-ios),
needed the same code. The reasoning is recorded from the iOS side in its
[ADR 0002](https://github.com/purlay/purlay-ios/blob/main/docs/decisions/0002-shared-swift-packages.md).

**Decision.** `PurlayContract`, `PurlayTokens`, `PurlayKit` and `PurlayTestSupport`, the `PurlayGen` generator, the contract pin
and the live-server contract tests live in [`purlay-swift`](https://github.com/purlay/purlay-swift). This repository asks for a
released version (`from:` in `project.yml` and in `Packages/PurlayUI/Package.swift`) and keeps only `PurlayUI`, the views, and the
app shell. The wire contract itself stays defined in the server repository and is never written by hand here.

**Rejected** (from the iOS record). *Copying into each app:* sign-in and realtime drift between the two. *iOS consuming this
repository's packages:* ties iOS to the Mac app's release cadence. *Kotlin Multiplatform:* trades platform-native feel for a shared runtime.

**Consequences.** + A fix to the engine is made once and picked up by version. − A change that needs both a model change and a
screen is two changes in two repositories, in order: `purlay-swift` first, then the pin here.
− The two pins must agree: `scripts/enforcement` fails if `project.yml` and the package ask for different versions
(`docs/runbooks/bump-shared-package.md`). − Behaviour tests of the model are in `purlay-swift`, not here.
