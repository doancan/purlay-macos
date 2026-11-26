# Move to a new `purlay-swift`

The contract, tokens and client engine come from [`purlay-swift`](https://github.com/purlay/purlay-swift), pinned by version
([ADR 0002](../decisions/0002-contract-tokens-and-engine-from-purlay-swift.md)). Order matters: the shared package first, then the pin here.

## 1. In `purlay-swift`

Make the change there and release it (its own `docs/development/releasing.md`). A change that needs both the model and a screen is
two changes: do not start the one here until the release exists.

## 2. Here

1. Raise the version in **both** places, to the same number:
   - `project.yml`, under `packages: PurlaySwift: from:`
   - `Packages/PurlayUI/Package.swift`, `.package(url: "https://github.com/purlay/purlay-swift", from: "…")`

   `scripts/enforcement` fails if they differ (`pins`), and `--demo` proves it does.
2. `make verify`. XcodeGen regenerates the project and the build resolves the package; `Package.resolved` is not committed.
3. If the contract moved to a newer server, state it in `docs/product/features/client-behaviour.md` ("Server features": the server the contract is pinned to,
   and the oldest the build reads) and in the changelog if a person would notice.
4. The change is `chore: take purlay-swift X.Y.Z`, with the screens that needed it, if any, in their own commits.

## Shared files

Some files are one file kept in several repositories: `purlay-swift` owns `.swift-format`, `NOTICE` and the scripts
`check-shared-files`, `check-branch`, `install-xcodegen` and `install-gitleaks`; the server repository owns `LICENSE`, `CLA.md`, `SECURITY.md`
and `.editorconfig`. Change them at the owner, then copy the file byte for byte. `scripts/check-shared-files` compares each with its owner's
`main` and fails on any difference, so **the owner's change is merged first**: until then the check reports the new copy as missing or different.
It needs a token to read the private repositories: `GITHUB_TOKEN="$(gh auth token)"`.
