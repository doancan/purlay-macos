# 0001. One verify entry point, and a secret scan in it

Status: accepted, 2026-11-26. The lanes are a retroactive record (they have run in CI since the contract moved to `purlay-swift`); the `make` entry point and the secret scan are new with this record.

**Context.** `scripts/verify` holds everything the pipeline checks, in lanes (`rules`, `test`, `app`) that CI runs side by side
from a warm compilation cache. There was no stable name for "what must pass before a change is done", and nothing looked for a
secret in the history. Swift Package Manager has no standard vulnerability scanner.

**Decision.**
- `scripts/verify` stays the home of the lanes. A root `Makefile` is only the stable entry point and decides nothing:
  `make setup` installs the pinned tools, `make verify` runs `rules`, `test` and `app` (what a pull request needs),
  `make verify-security` runs the `security` lane, `make verify-all` runs every lane with the Release build (what a release runs).
- The `security` lane scans the whole git history with gitleaks. `scripts/install-gitleaks` installs one pinned version from its
  release and checks the archive against a digest pinned for the platform, as `scripts/install-xcodegen` does. CI runs the lane as
  its own job with the full history on every pull request and push, and the final `verify` check requires it to succeed: a change
  that only touches documents still gets the scan. The release workflow checks out the full history for the same reason.
- `scripts/install-gitleaks` is one file kept in the three Swift repositories; `purlay-swift` owns it and
  `scripts/check-shared-files` compares the copies.
- No vulnerability scan of Swift packages is run, because no standard tool exists for them. The exposure is kept small instead:
  `scripts/enforcement` refuses any dependency beyond Sparkle and `purlay-swift`, Sparkle is pinned to an exact version
  (`project.yml`), and `purlay-swift` is pinned by version. Moving the Sparkle pin is a step of the release runbook (TD-003).

**Rejected.**
- *The lanes written in the Makefile:* a second home for the same commands, and CI runs the lanes by name.
- *gitleaks from Homebrew:* unpinned and ten seconds or more slower on a hosted runner, which is why XcodeGen moved off it too.
- *Relying on the host's own secret scanning:* a setting of the organisation, not visible in or checkable from the repository.

**Consequences.** + A secret in any commit fails the check wherever it was committed. + One name for "done". − A new file kept
identical in three repositories, and a version and three digests to move by hand when gitleaks is updated. − `check-shared-files`
reports the new file as missing until `purlay-swift` has it on `main`: it merges first.
