# Release

A release is a tag. `.github/workflows/release.yml` does the rest, on a hosted `xcode-27` runner, in up to 90 minutes. Nothing is
signed or notarized on a person's Mac, and no signing material is in the repository.

## Before tagging

1. **Changelog.** Move what is under `## [Unreleased]` in `CHANGELOG.md` to `## [X.Y.Z] — YYYY-MM-DD`. Only paragraphs, level-three
   headings, bullets and bold text are accepted. Check it renders: `scripts/release-notes X.Y.Z "$(mktemp -d)"` writes
   `release-notes.md` and the Sparkle HTML, or fails with the reason.
2. **Version.** Set `MARKETING_VERSION` in `Config/Base.xcconfig` to `X.Y.Z`, and the version in the caption under the screenshot in `README.md`.
   `CURRENT_PROJECT_VERSION` stays: the workflow uses its run number.
3. **Sparkle.** Look at Sparkle's latest release (`gh release view --repo sparkle-project/Sparkle`). If it is newer than `exactVersion` in
   `project.yml`, move the pin, say so in `docs/development/DEVELOPMENT.md` ("Updates use Sparkle …") and check `licenses/Sparkle.txt`. A security fix is
   not left for the next release (TD-003).
4. **The `purlay-swift` pin** is the version this release should ship with ([`bump-shared-package.md`](bump-shared-package.md)).
5. **Verify everything,** the Release build included: `GITHUB_TOKEN="$(gh auth token)" make verify-all && make verify-security`.
6. Commit as `chore: release X.Y.Z` (the three files above), merge to `main` with a green check.

## Tagging

```sh
git switch main && git pull
git tag vX.Y.Z && git push origin vX.Y.Z
```

The workflow refuses a tag that is not `v` plus `MARKETING_VERSION`, runs every lane of `scripts/verify` on the full history,
imports the Developer ID certificate into a throwaway keychain, builds arm64, signs Sparkle's nested helpers first
(`scripts/sign-release`), notarizes with Apple and staples, makes the ZIP and `SHA256SUMS`, generates the Sparkle appcast, **verifies the
Ed25519 signatures of the appcast, the archive and the notes**, and publishes the GitHub release with the notes from the changelog.
The keychain and the certificate are removed at the end whatever happened.

Secrets it needs (repository secrets): `MACOS_CERTIFICATE_P12`, `MACOS_CERTIFICATE_PASSWORD`, `APPLE_ID`, `APPLE_TEAM_ID`,
`APPLE_APP_SPECIFIC_PASSWORD`, `SPARKLE_PRIVATE_KEY`. The Sparkle public key is `SUPublicEDKey` in `App/Resources/Info.plist`; the private key is never committed.

## After

1. The release has `Purlay-X.Y.Z-macOS-arm64.zip`, `SHA256SUMS`, `appcast.xml` and the notes HTML. Download the ZIP and check it: `shasum -a 256 -c SHA256SUMS`.
2. `https://github.com/purlay/purlay-macos/releases/latest/download/appcast.xml` now names X.Y.Z (installed apps read that URL; it follows the latest release).
3. By hand, on a Mac that has the previous version: **Purlay → Check for Updates…** offers X.Y.Z, and the update installs and opens
   (nothing automated reaches this path, TD-004). First launch of the new build: notifications, Dock badge and login item still ask or behave as before.

## When it goes wrong

- **Never edit a published asset**: the feed, the notes and the archive are signed together. A bad release is superseded by a new patch release.
- A failed run before "Publish GitHub release" has published nothing: fix, delete the tag (`git push origin :refs/tags/vX.Y.Z`; the tag was never a release), and tag again.
- Notarization waits up to 60 minutes; a rejected submission prints Apple's reason in the log.
- The original 0.1.0 has no updater: someone still on it installs a newer release by hand once.
