# Developing Purlay for macOS

The native macOS client for [Purlay](https://github.com/doancan/purlay): Swift, SwiftUI with AppKit where it
earns its place, drawn in Liquid Glass. Decided in `DECISIONS.md` D-186 of the server repository, which also owns
the contract this client is generated from.

Built with Swift 6 and SwiftUI for macOS 26 and later on Apple Silicon (arm64). Native split navigation, Liquid Glass controls, a translucent sidebar,
threads, an inbox, saved messages, drafts, channel members and file browsing share the same client model.

Build with Xcode 27 or newer:

```sh
xcodegen generate
xcodebuild -project Purlay.xcodeproj -scheme Purlay -configuration Debug -destination 'platform=macOS,arch=arm64' build
```

Connect to a compatible Purlay server on first launch. The app is a client and does not start a server itself.
For local development, `PURLAY_DEV_SERVER` and `PURLAY_DEV_SESSION` can seed a session in Debug builds only.

Run `swift test` inside a package to check that layer, or `scripts/verify` for the full repository checks.

Releases are built by `.github/workflows/release.yml` when a `v` tag matching `MARKETING_VERSION` is pushed.
The workflow tests the packages, builds for Apple Silicon (arm64), signs with Developer ID, notarizes with Apple,
and publishes a stapled app ZIP and SHA-256 checksum. Signing uses the repository secrets `MACOS_CERTIFICATE_P12`
(base64-encoded PKCS#12), `MACOS_CERTIFICATE_PASSWORD`, `APPLE_ID`, `APPLE_TEAM_ID`, and `APPLE_APP_SPECIFIC_PASSWORD`.
The contract bundle is rebuilt from the server commit pinned in the workflow and checked against `Contract/contract.lock`.

Updates use Sparkle 2.10.1. Release builds offer **Purlay > Check for Updates…** and an Updates settings tab;
Debug builds leave the updater stopped and allow loading the prebuilt framework with ad-hoc signing;
Release builds retain library validation and require Developer ID signing to run with Sparkle. Both the appcast and update archive are Ed25519-signed, and archives are
verified before extraction. The release workflow re-signs Sparkle's nested helpers with Developer ID before notarization,
then publishes `appcast.xml` beside the arm64 ZIP. The feed URL follows the latest GitHub release.

`SPARKLE_PRIVATE_KEY` is an additional GitHub Actions secret. Its public counterpart is committed in `Info.plist`;
the private key must never be committed. The release workflow uses its increasing run number for `CFBundleVersion`.
The original 0.1.0 release has no updater: install the first Sparkle-enabled release manually once.

Inbox type filters (All, Mentions, DMs, Threads) work alongside All / Unread and use the server's
[notification type filter](https://github.com/doancan/purlay/issues/787). Each selection starts a new page sequence;
All omits `types`, and Threads requests both replies and resolutions. Mark All Read only affects visible rows.
The client sends `types` only when `/api/client` advertises `capabilities.notificationTypeFilters: true`.
Missing/false capabilities use local filtering without probing unsupported query parameters; Load More remains
available for older history. Errors from a server advertising support remain visible instead of changing behavior.

Connections check `/api/client` for the server contract and minimum supported macOS app version. Older handshake
responses without the subsequently added `auth.oidc` field remain readable so compatibility checks still run.
Additive features are discovered from the current handshake's optional capabilities, independently of release
and contract versions. Unknown capability names are ignored; only a known boolean `true` enables a feature.

Settings group device preferences, profile/account details and workspace administration in a native sidebar.
The workspace's active membership controls navigation: owners/admins see workspace settings, members, invitations,
integrations and audit; only owners see data/history. Ordinary members see device and account settings.
Server administration is excluded. Members are read from the generated API, with loading, empty and retry states.
Invitations, role changes and other server-owned writes open their existing web pages and may require browser sign-in.
Invitation links admit signed-in people as members, last seven days and are reusable until expired or revoked.


## Release notes

`CHANGELOG.md` is the source for both GitHub and Sparkle release notes. Before tagging a version, add its entry and update `MARKETING_VERSION`. The release workflow runs `scripts/release-notes VERSION dist`, generates self-contained HTML for Sparkle, signs that HTML together with the appcast and archive, verifies all three signatures, and uploads the notes as a release asset. Do not edit signed release assets after publication.
