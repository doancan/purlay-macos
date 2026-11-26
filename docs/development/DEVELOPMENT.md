# Developing Purlay for macOS

The native macOS client for [Purlay](https://github.com/purlay/purlay): Swift, SwiftUI with AppKit where it
earns its place, drawn in Liquid Glass. Decided in `DECISIONS.md` D-186 of the server repository, which also owns
the contract this client is generated from. What the app does is in [`../product/features/client-behaviour.md`](../product/features/client-behaviour.md);
how it is put together is in [`../architecture/overview.md`](../architecture/overview.md).

Built with Swift 6 and SwiftUI against the macOS 27 SDK (Xcode 27), on Apple Silicon (arm64). macOS 27 is the
primary target and uses its newest APIs; macOS 26, which introduced Liquid Glass, stays supported as the deployment
floor, so anything that needs 27 sits behind `#available(macOS 27, *)` with a 26 path beside it
([ADR 0003](../decisions/0003-platform-floor-and-architecture.md)).

## Set up and build

```sh
make setup                 # XcodeGen and gitleaks at their pinned versions, checked against pinned digests
xcodegen generate
xcodebuild -project Purlay.xcodeproj -scheme Purlay -configuration Debug -destination 'platform=macOS,arch=arm64' build
```

The app signs in only to `https://purlay.app` (`ServerAddress.hosted`); it is a client and does not start a server itself.
For local development, `PURLAY_DEV_SERVER` points a Debug build at another server, and with `PURLAY_DEV_SESSION` seeds a session there.

## Check a change

```sh
make verify            # rules, format and tests, the Debug app: what a pull request needs
make verify-security   # the git history scanned for secrets
make verify-all        # every lane, with the Release build too: what a release runs
```

`scripts/verify` holds the lanes (`rules`, `test`, `app`, `security`); the Makefile is only the stable entry point
([ADR 0001](../decisions/0001-verify-entry-point-and-secret-scan.md)). To run a single lane while working, call it directly:
`scripts/verify test` runs the format check, `PurlayUI`'s tests and the screens' snapshots.
The repositories are public, so `scripts/check-shared-files` needs no token to read its owners' copies, but an anonymous address may make 60 GitHub requests an hour and one run makes ten:
`GITHUB_TOKEN="$(gh auth token)" make verify` lifts the limit. Without network, `PURLAY_OFFLINE=1` skips that one check; CI never does.

Compiled code is cached by content in `~/Library/Caches/dev.purlay` (or `PURLAY_CACHE_DIR`), so the second run is much faster than the first.

## Signing on this Mac

`scripts/dev-signing` makes a self-signed identity for this Mac's development builds and names it in `Config/Local.xcconfig`
(ignored by git), so the keychain remembers "Always Allow" across rebuilds. CI and other Macs sign ad hoc. Releases are signed with
Developer ID by the release workflow, never with the development identity.

## Releases

Releases are built by `.github/workflows/release.yml` when a `v` tag matching `MARKETING_VERSION` is pushed; the steps, and what
to check before and after, are in [`../runbooks/release.md`](../runbooks/release.md).
The workflow runs every lane of `scripts/verify`, with the Release build, builds for Apple Silicon (arm64), signs with Developer ID,
notarizes with Apple, and publishes a stapled app ZIP and SHA-256 checksum. Signing uses the repository secrets `MACOS_CERTIFICATE_P12`
(base64-encoded PKCS#12), `MACOS_CERTIFICATE_PASSWORD`, `APPLE_ID`, `APPLE_TEAM_ID`, and `APPLE_APP_SPECIFIC_PASSWORD`.
The wire contract, the tokens and the client engine come from [`purlay-swift`](https://github.com/purlay/purlay-swift), pinned by version in `project.yml` and `Packages/PurlayUI/Package.swift`; the contract pin and its generator live there ([`bump-shared-package.md`](../runbooks/bump-shared-package.md)).

Updates use Sparkle 2.10.1. Release builds offer **Purlay > Check for Updates…** and an Updates settings tab;
Debug builds leave the updater stopped and allow loading the prebuilt framework with ad-hoc signing;
Release builds retain library validation and require Developer ID signing to run with Sparkle. Both the appcast and update archive are Ed25519-signed, and archives are
verified before extraction. The release workflow re-signs Sparkle's nested helpers with Developer ID before notarization,
then publishes `appcast.xml` beside the arm64 ZIP. The feed URL follows the latest GitHub release.

`SPARKLE_PRIVATE_KEY` is an additional GitHub Actions secret. Its public counterpart is committed in `Info.plist`;
the private key must never be committed. The release workflow uses its increasing run number for `CFBundleVersion`.
The original 0.1.0 release has no updater: install the first Sparkle-enabled release manually once.

## Release notes

`CHANGELOG.md` is the source for both GitHub and Sparkle release notes. Before tagging a version, add its entry and update `MARKETING_VERSION`. The release workflow runs `scripts/release-notes VERSION dist`, generates self-contained HTML for Sparkle, signs that HTML together with the appcast and archive, verifies all three signatures, and uploads the notes as a release asset. Do not edit signed release assets after publication.

## Languages

The app is in English and Turkish. Every string lives in one catalog, `App/Resources/Localizable.xcstrings`, which the packages
read through the main bundle (`Text("…")` and `String(localized:)` look there), so a string is written in the code in English and
needs no key of its own. `knownRegions` in `project.yml` lists the languages.

- `scripts/localize` builds with string extraction and adds the strings the code now uses to the catalog.
- Give each new string its Turkish value in the catalog, with state `translated`, then run `scripts/localize --check`. It refuses a
  string with no Turkish value, one that is not final, and one whose format specifiers (`%@`, `%lld`) differ from the English;
  `scripts/verify` runs it. A string with no letters in it (a symbol, a number) needs no translation.
- Turkish addresses the person as "sen", as the web client does; its wording for the same concepts is in
  `apps/web/src/i18n/catalogue/tr.ts` of the server repository, and the two clients should read alike.
- To see the app in Turkish while developing: `Purlay -AppleLanguages "(tr)"`.
