# Contributing to Purlay for macOS

The rules every Purlay repository shares (branches, commits, pull requests, the agreement) are in the organisation's
[CONTRIBUTING.md](https://github.com/purlay/.github/blob/main/CONTRIBUTING.md). This file is what is specific to this one.

## Before you push

```sh
scripts/verify
```

Three lanes, which CI runs side by side: `rules` (project, branch name, shared files, architecture rules with a demonstration that
each refuses its violation, Turkish strings), `test` (format, `PurlayUI`'s tests and the screens' snapshots) and `app` (the Debug
build, App Transport Security, the sandbox's entitlements). With no argument every lane runs and the Release build is checked
too, which is what a release does. Compiled code is cached by content, so the second run is much faster than the first; keep a
pull request's check short, and say why in its description if a change makes it slower. A pull request that changes only documents
(`docs/`, `*.md`, `LICENSE`, `NOTICE`, `.editorconfig`, `CODEOWNERS`) skips the compiling lanes; `verify` accepts that only when the
`changes` job said so.

## Where code goes

The wire contract, tokens and client engine are in [`purlay-swift`](https://github.com/purlay/purlay-swift): change them there and
raise the pin here (`project.yml` and `Packages/PurlayUI/Package.swift`; `scripts/enforcement` fails if the two disagree). Views are
in `PurlayUI` and open no connection; the app target is a shell. Built with the macOS 27 SDK and its newest APIs, behind
`#available` with a macOS 26 path beside them.

## Strings and accessibility

Strings are in `App/Resources/Localizable.xcstrings`, English and Turkish; `scripts/localize` adds new ones and `--check` refuses a
missing translation. Every control has an accessibility label, text uses Dynamic Type, and the system's Reduce Transparency,
Increase Contrast and Reduce Motion are followed.

## Shared files

`LICENSE`, `CLA.md`, `SECURITY.md` and `.editorconfig` belong to `purlay/purlay`; `.swift-format`, `NOTICE` and the shared scripts
belong to `purlay/purlay-swift`. Change them at their owner and copy; `scripts/check-shared-files` fails on any difference.

## Releases

Pushing a `v*` tag matching `MARKETING_VERSION` runs the release workflow (see [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md)).
