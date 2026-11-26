# Code conventions

What is true of this code today, and what `scripts/enforcement` or the compiler refuses. Rules that a tool enforces name the tool.

## Tools

| Purpose | Tool | Config |
|---|---|---|
| Format | `swift-format lint --strict` (the toolchain's) | `.swift-format` (owned by `purlay-swift`, line length 120, 4 spaces) |
| Compiler | Swift 6 language mode, complete strict concurrency, warnings are errors | `Config/Base.xcconfig`, `Packages/PurlayUI/Package.swift` |
| Test | Swift Testing (`@Test`, `#expect`); no XCTest in the package | `Packages/PurlayUI/Tests` |
| Architecture rules | `scripts/enforcement` (and `--demo`, which plants each violation and requires the refusal) | `scripts/enforcement` |
| Strings | `scripts/localize --check` | `App/Resources/Localizable.xcstrings` |
| Verification | `make verify` (lanes in `scripts/verify`) | `Makefile`, [ADR 0001](../decisions/0001-verify-entry-point-and-secret-scan.md) |

## Layout and naming

- The app target is a shell (`App/`): scenes, commands and adapters to the system. What the app does lives in `PurlayUI` and `purlay-swift`.
- One type or one screen per file, the file named for it. Extensions of the model by feature are in `purlay-swift` (`AppModel+Issues`).
- `project.yml` is the definition of the project; `Purlay.xcodeproj` is generated and never committed (`scripts/verify rules` fails if it is tracked).
- New files in `Packages/PurlayUI/Sources/PurlayUI` need no registration: the package takes the folder.

## Layers (enforced)

- **PurlayUI opens no connection.** `URLSession`, `URLRequest`, `NWConnection` and `URLSessionWebSocketTask` are refused in `Packages/PurlayUI/Sources`; the network is reached only through `PurlayKit`'s protocols.
- **Only `App/Updates/` imports Sparkle.**
- **No dependency beyond Sparkle and `purlay-swift`.** Any other `.package(url:)` in `Packages/` or `project.yml` is refused. A new dependency needs an ADR and a change to `scripts/enforcement`.
- **One macOS floor and one `purlay-swift` pin.** The build settings, `project.yml` and the package must say the same numbers.
- Views read a model and call it. A view never makes a decision the model owns, and the app shell knows nothing about a message's content.

## Errors and sentences

- Errors are typed in `PurlayKit` and matched exhaustively; the server's own `message` is English and written for a log, so it is **never shown**.
- Every sentence a person reads is in `Strings.swift` (or the catalog), so each is a key that can be translated. A system notice says where and why, never what was said.
- No empty `catch`. A failure is shown, retried or logged with its cause; it is not swallowed.

## Production code cannot trap (enforced)

No `try!`, `as!`, `fatalError(`, `unsafelyUnwrapped`, force unwrap (`x!`) or implicitly unwrapped optional (`var x: T!`) in `App/` or `Packages/*/Sources`.
`preconditionFailure` stays only for the two invariants that a test proves. A trap cannot be caught, so the rule is prevention.

## Concurrency

- `@unchecked Sendable` and `nonisolated(unsafe)` are refused unless the line carries `enforcement-allow` and a reason (no line does today).
- Views are on the main actor through SwiftUI; other types that touch AppKit are marked `@MainActor`. Shared mutable state lives in an actor or behind the model.
- `DispatchQueue.main.async` is used for one run-loop turn that AppKit needs, and `Task.detached` for file and image work off the main actor; each existing use says why on or above the line. A new one does the same.
- View-bound work uses `.task`, which cancels with the view.

## Tests

- New behaviour comes with a test; a bug fix starts with a failing regression test. Test behaviour a document states, not the implementation.
- Where: `Packages/PurlayUI/Tests/PurlayUITests` for views, state that lives in the UI and the screens drawn from state; the model's behaviour is tested in `purlay-swift`.
- Test doubles at the system's edge only (network, Keychain, clock, timers), as protocol implementations. Never replace the code under test.
- A new or changed screen that shows data adds its loading, empty and failed states to `SnapshotTests`.

## Accessibility and appearance

Every control has an accessibility label; text uses the system's type; Reduce Transparency, Increase Contrast and Reduce Motion are followed.
Colour, spacing, type and motion come from tokens through `TokenBinding.swift` and, for the native look, `NativePalette.swift`; a view names a token and does not choose a colour of its own.
Liquid Glass is the system's on the system's bars, and a switch (Settings → Appearance) turns off what the app draws itself.

## macOS specifics

- **Sandbox and entitlements are an allowlist** (`App/Resources/Purlay.entitlements`, checked declared and signed by `scripts/verify app`). A new entitlement needs a reason and a change to the allowlist in `scripts/verify`.
- **App Transport Security is strict in Release** and relaxed for localhost in Debug only, through a preprocessor key (`PURLAY_PLIST_DEFINITIONS`) that Release must not define.
- **Keychain.** The session is kept in the Keychain through `purlay-swift`'s store. Development builds are signed with this Mac's own identity (`scripts/dev-signing`) so that "Always Allow" survives a rebuild; ad-hoc builds can be asked for the session again.
- **The app outlives its last window** (`applicationShouldTerminateAfterLastWindowClosed` is false) so the socket stays open and a notification can arrive. Work that must survive a closed window starts in the app, not in a view's `.task`.
- **Permissions** (notifications, Dock badge, login item) are asked for the first time there is something to tell, never on launch. They cannot be tested; they are checked by hand on a signed build.
- **Signing.** Releases are signed with Developer ID, with Sparkle's nested helpers signed first (`scripts/sign-release`). Secrets are only in GitHub Actions, never in the repository; the Sparkle public key is in `Info.plist`.

## Forbidden patterns

| Forbidden | Instead | Why |
|---|---|---|
| `try!`, `as!`, `x!`, `T!`, `fatalError(` in production code | typed errors, `guard`, optional handling | enforced; a trap cannot be caught |
| `@unchecked Sendable`, `nonisolated(unsafe)` without `enforcement-allow` and a reason | an actor, or a value type | enforced |
| `URLSession` and friends in `PurlayUI` | `PurlayKit`'s protocols | enforced |
| `import Sparkle` outside `App/Updates/` | `UpdateController` | enforced |
| a dependency beyond Sparkle and `purlay-swift` | an ADR first | enforced |
| committing `Purlay.xcodeproj` or `Package.resolved` | `project.yml` is the definition | `scripts/verify rules`, `.gitignore` |
| a string with no final Turkish value, or with different format specifiers | add the Turkish value to the catalog | `scripts/localize --check` |
| editing a signed release asset after publication | cut a new release | the feed and the notes are signed together |
| `// swift-format-ignore` or a lowered concurrency level | fix the code | the base is strict |

## Old patterns, not for new code

- **Citations of plan sections** in comments (`§12.3`, `M-8`, `M6-1`): they point at a plan that is not in this repository (TD-001). Cite a document, an ADR or the server's `D-xxx` decision instead. `D-xxx` are decisions of the server repository's `DECISIONS.md`.
- **Colour literals** outside `TokenBinding.swift` are in `NativePalette.swift` only (TD-002); do not add another place.
