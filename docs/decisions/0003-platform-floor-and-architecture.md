# 0003. macOS 26 floor, built with the macOS 27 SDK, Apple Silicon only

Status: accepted (retroactive record: it is what `project.yml`, `Config/Base.xcconfig` and the changelog already state).

**Context.** The app is drawn in Liquid Glass, which macOS 26 introduced. The deployment floor, the SDK it is built with and the
architectures it ships are set in `Config/Base.xcconfig` (`MACOSX_DEPLOYMENT_TARGET = 26.0`, `ARCHS = arm64`) and
`project.yml` (`macOS: "26.0"`), and `Packages/PurlayUI/Package.swift` says `.macOS(.v26)`.

**Decision.**
- The floor is macOS 26. Everything that needs macOS 27 sits behind `#available(macOS 27, *)` with a 26 path beside it.
- It is built with the macOS 27 SDK (Xcode 27) and uses that SDK's newest APIs: macOS 27 is the primary target.
- It ships for Apple Silicon (arm64) only; Intel builds are not provided (changelog 0.1.0).
- One floor, one number: `scripts/enforcement` fails if the build settings, the project and the package disagree.

**Rejected.** The alternatives that were weighed, and why Intel was dropped and an earlier floor was not kept, are not recorded
anywhere in the repository: see Q-001 in [`../product/requirements.md`](../product/requirements.md).

**Consequences.** + No second design for pre-Liquid-Glass systems. + A single architecture to sign, notarize and test.
− Intel Macs and macOS 15 or earlier cannot run the app. − Two code paths wherever macOS 27 adds an API.
