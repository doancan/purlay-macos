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

Message search supports channel and author filters using the existing `channelId` and `senderId` API parameters.
Filters stay attached to every result page. Recent searches retain their filters, are stored separately for each
server/account/workspace, and can be cleared from the search window.

Saved messages can be completed, archived or moved back to In Progress from their action menu. Each state
supports pagination, loading and retry. State changes use the existing saved-message API and refresh across
devices; an in-flight operation cannot restore another session's data after sign-out.

Open Topics (Option-Command-U) collects unresolved conversations across the workspace, with channel filtering,
pagination, retry and direct resolution. Opening a row takes you to its channel and thread. Thread updates
refresh the page while it is open. Viewing Inbox or Open Topics does not mark the hidden channel as read.

Open a conversation in its own window from the channel menu or Option-Command-N. Each window has independent
navigation, thread, search and presentation state; the session shares one socket and durable send queue, saved
markers, people and drafts. Menu commands target the focused window. Closing a conversation window leaves the
session running; signing out clears all its windows. Restored windows validate the server, user and workspace.

The toolbar switcher keeps multiple servers and workspaces connected. Adding a server leaves existing sessions
running; selecting a membership on the same server reuses its saved credential. Each workspace has its own
navigation, drafts and durable outbox. The first account keeps the existing storage location; subsequent sessions
use separate preferences and directories. The Dock badge sums active sessions, and notifications carry their
source session so identical channel IDs cannot open a different server. Sign-out clears every workspace and
conversation window for that server, leaving other servers connected. Workspaces visited in the switcher reopen
on launch. The keychain still keeps one account per server address.

The sidebar filter menu opens Organize Sidebar. Custom groups can be added, renamed, reordered and removed;
removing a group returns its conversations to their default sections. Channel menus move conversations between
groups or up/down within a section; dragging reorders an unfiltered section. A section's context menu resets its
conversation order. The arrangement is local to this Mac and scoped by server, account and workspace. It is shared
by companion windows and never changes membership, permissions, or server-side starred state.

Channel and message menus offer Copy App Link, using `purlay://open?url=<encoded web permalink>`.
The registered app URL handler validates the origin, workspace slug and identifiers before routing the link.
File → Open Purlay Link (Option-Command-O) also accepts ordinary web permalinks. Links select the matching server
and workspace, wait through sign-in when needed, and show an error for inaccessible destinations. A newer link
supersedes a pending navigation. `purlay://auth` remains owned by browser authentication. Arbitrary self-hosted
HTTPS domains are not registered as universal links; the explicit app link or paste action opens them natively.

Scheduled messages require a server advertising `capabilities.scheduledMessages`. The composer clock button
opens a local-time date picker after all attachments finish uploading. Scheduled lists pending and failed
messages with edit/cancel actions and refreshes every 15 seconds only while open. Scheduling uses one stable
request ID across retries and clears draft text/files only after confirmation; late responses cannot restore
a signed-out session. The server owns delivery while the app is closed. Ship the matching server migration
and API from `codex/desktop-scheduling` before enabling the native feature on an installation.

Message reminders require `capabilities.messageReminders`. A message’s Remind Me action sets a private
server reminder; Reminders lists pending items with change-time, cancel and jump-to-message actions. Due
items appear in Inbox. The confirmed time also registers a macOS notification, so an authorized Mac can
remind after Purlay quits. The alert carries a deep link and no message content. Time is stored as an absolute
instant. Native notifications follow macOS permissions/Focus and the app’s notification preference.
Changes from other devices refresh through `REMINDERS_UPDATED`; offline Macs reconcile when they reconnect.
Signing out removes this account’s pending alerts. Reminder notifications do not inflate unread-message counts.

Settings group device preferences, profile/account details and workspace administration in a native sidebar.
The workspace's active membership controls navigation: owners/admins see workspace settings, members, invitations,
integrations and audit; only owners see data/history. Ordinary members see device and account settings.
Server Settings appears in its own administration group only when the signed-in user's `isServerAdmin` is true,
independently of their workspace role, and opens the existing `settings/server` web route.
Members are read from the generated API, with loading, empty and retry states.
Invitations, role changes and other server-owned writes open their existing web pages and may require browser sign-in.
Invitation links admit signed-in people as members, last seven days and are reusable until expired or revoked.


## Message deletion

The message menu offers **Delete for Me** when the server advertises `personalMessageDeletion`.
The server keeps this choice per account, across devices; it does not remove anyone else's content or files.
Search, saved messages, pins, inbox items and pending reminders omit personally deleted messages.
A deleted root keeps an empty placeholder when it has replies, so the thread remains reachable.
Private events and replay projections also clear companion windows; older in-flight reads cannot restore the words.
**Delete for Everyone** uses the existing server deletion rule: the author, workspace owner or workspace admin.
Both actions require an explicit choice in the same confirmation dialog, and failures retain the message.

## Release notes

`CHANGELOG.md` is the source for both GitHub and Sparkle release notes. Before tagging a version, add its entry and update `MARKETING_VERSION`. The release workflow runs `scripts/release-notes VERSION dist`, generates self-contained HTML for Sparkle, signs that HTML together with the appcast and archive, verifies all three signatures, and uploads the notes as a release asset. Do not edit signed release assets after publication.
