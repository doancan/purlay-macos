# Purlay for macOS

The native macOS client for [Purlay](https://github.com/doancan/purlay): Swift, SwiftUI with AppKit where it
earns its place, drawn in Liquid Glass. Decided in `DECISIONS.md` D-186 of the server repository, which also owns
the contract this client is generated from.

Built with Swift 6 and SwiftUI for macOS 26 and later. Native split navigation, Liquid Glass controls, a translucent sidebar,
threads, an inbox, saved messages, drafts, channel members and file browsing share the same client model.

Build with Xcode 26 or newer:

```sh
xcodegen generate
xcodebuild -project Purlay.xcodeproj -scheme Purlay -configuration Debug -destination 'platform=macOS,arch=arm64' build
```

Connect to a compatible Purlay server on first launch. The app is a client and does not start a server itself.
For local development, `PURLAY_DEV_SERVER` and `PURLAY_DEV_SESSION` can seed a session in Debug builds only.

Run `swift test` inside a package to check that layer, or `scripts/verify` for the full repository checks.

Releases are built by `.github/workflows/release.yml` when a `v` tag matching `MARKETING_VERSION` is pushed.
The workflow tests the packages, builds for Apple Silicon and Intel, signs with Developer ID, notarizes with Apple,
and publishes a stapled app ZIP and SHA-256 checksum. Signing uses the repository secrets `MACOS_CERTIFICATE_P12`
(base64-encoded PKCS#12), `MACOS_CERTIFICATE_PASSWORD`, `APPLE_ID`, `APPLE_TEAM_ID`, and `APPLE_APP_SPECIFIC_PASSWORD`.
The contract bundle is rebuilt from the server commit pinned in the workflow and checked against `Contract/contract.lock`.
