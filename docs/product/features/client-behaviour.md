# Client behaviour

What the macOS client does, feature by feature, where a behaviour is not obvious from the screen. The requirement each
belongs to is in [`../requirements.md`](../requirements.md). The model code named here lives in `PurlayKit`
([`purlay-swift`](https://github.com/purlay/purlay-swift)); the views are in `Packages/PurlayUI`.

## Inbox

Inbox type filters (All, Mentions, DMs, Threads) work alongside All / Unread and use the server's
[notification type filter](https://github.com/purlay/purlay/issues/787). Each selection starts a new page sequence;
All omits `types`, and Threads requests both replies and resolutions. Mark All Read only affects visible rows.
The client sends `types` only when `/api/client` advertises `capabilities.notificationTypeFilters: true`.
Missing/false capabilities use local filtering without probing unsupported query parameters; Load More remains
available for older history. Errors from a server advertising support remain visible instead of changing behavior.

## Connection and capabilities

Connections check `/api/client` for the server contract and minimum supported macOS app version. Older handshake
responses without the subsequently added `auth.oidc` field remain readable so compatibility checks still run.
Additive features are discovered from the current handshake's optional capabilities, independently of release
and contract versions. Unknown capability names are ignored; only a known boolean `true` enables a feature.

## Search

Message search supports channel and author filters using the existing `channelId` and `senderId` API parameters.
Filters stay attached to every result page. Recent searches retain their filters, are stored separately for each
server/account/workspace, and can be cleared from the search window.

## Saved messages

Saved messages can be completed, archived or moved back to In Progress from their action menu. Each state
supports pagination, loading and retry. State changes use the existing saved-message API and refresh across
devices; an in-flight operation cannot restore another session's data after sign-out.

## Open Topics

Open Topics (Option-Command-U) collects unresolved conversations across the workspace, with channel filtering,
pagination, retry and direct resolution. Opening a row takes you to its channel and thread. Thread updates
refresh the page while it is open. Viewing Inbox or Open Topics does not mark the hidden channel as read.

## Conversation windows

Open a conversation in its own window from the channel menu or Option-Command-N. Each window has independent
navigation, thread, search and presentation state; the session shares one socket and durable send queue, saved
markers, people and drafts. Menu commands target the focused window. Closing a conversation window leaves the
session running; signing out clears all its windows. Restored windows validate the server, user and workspace.

## Workspaces and sessions

Sign-in is only at purlay.app (changelog 0.3.0): there is no server address to enter, a workspace of another server kept by an
earlier version is not opened, and a `purlay://` link to another server is refused. `PURLAY_DEV_SERVER` is the Debug-only way to another server.
The toolbar switcher moves between the workspaces of the signed-in account (⌘1 to ⌘9 in the Go menu). Each workspace has its own
navigation, drafts and durable outbox. The Dock badge sums active sessions, and notifications carry their source session so
identical channel IDs cannot open a different workspace. Sign-out clears every workspace and conversation window. Workspaces
visited in the switcher reopen on launch. The keychain still keeps one account per server address.
A workspace whose server has chat turned off, or whose channels are briefly not served, opens and offers its profile, members,
invitations and data pages in the browser, hides the chat menus, and says chat is off when a conversation link is opened.

## Sidebar groups

The sidebar filter menu opens Organize Sidebar. Custom groups can be added, renamed, reordered and removed;
removing a group returns its conversations to their default sections. Channel menus move conversations between
groups or up/down within a section; dragging reorders an unfiltered section. A section's context menu resets its
conversation order. The server keeps groups, their folding and each channel's `sidebarGroupId` (server D-284); this Mac keeps only the
order of sections and conversations, scoped by server, account and workspace and shared by companion windows. It never changes
membership, permissions, or server-side starred state. Groups an older version kept locally are sent once (`sendLegacyGroups`)
and stay on disk until the server has them.

## App links

Channel and message menus offer Copy App Link, using `purlay://open?url=<encoded web permalink>`.
The registered app URL handler validates the origin, workspace slug and identifiers before routing the link.
File → Open Purlay Link (Option-Command-O) also accepts ordinary web permalinks. Links select the matching workspace,
wait through sign-in when needed, and show an error for inaccessible destinations. A newer link
supersedes a pending navigation. `purlay://auth` remains owned by browser authentication. Arbitrary self-hosted
HTTPS domains are not registered as universal links; the explicit app link or paste action opens them natively.

## Scheduled messages

Scheduled messages require a server advertising `capabilities.scheduledMessages`. The composer clock button
opens a local-time date picker after all attachments finish uploading. Scheduled lists pending and failed
messages with edit/cancel actions and Send Now, and refreshes every 15 seconds only while open. Scheduling uses one stable
request ID across retries and clears draft text/files only after confirmation; late responses cannot restore
a signed-out session. The server owns delivery while the app is closed.

## Reminders

Message reminders require `capabilities.messageReminders`. A message's Remind Me action sets a private
server reminder; Reminders lists pending items with change-time, cancel and jump-to-message actions. Due
items appear in Inbox. The confirmed time also registers a macOS notification, so an authorized Mac can
remind after Purlay quits. The alert carries a deep link and no message content. Time is stored as an absolute
instant. Native notifications follow macOS permissions/Focus and the app's notification preference.
Changes from other devices refresh through `REMINDERS_UPDATED`; offline Macs reconcile when they reconnect.
Signing out removes this account's pending alerts. Reminder notifications do not inflate unread-message counts.

## Settings and administration

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

## Server features

The contract is pinned to server 0.8.0 (`Contract/contract.lock` in `purlay-swift`) and the oldest server this build reads is 0.5.0
(`CompatibleContracts.minimumServer`): a channel's `sidebarGroupId` is required from 0.5.0. `GET /api/me` types the server's `modules`
and each membership's grant; `AppModel.hasModule(_:)` decides what a workspace has, and a module this app does not know is ignored.

- **Updates** (`InboxEntry`, core inbox, `INBOX_UPDATED`): `AppModel+InboxUpdates`. A kind is said by its module and kind; one
  this app does not know is said by the module's name and only read.
- **Issues** (server D-254): `AppModel+Issues`, `IssuesViews`; search adds the find's issue hits (`findAcrossSources`).
- **Away** (server D-257): `setAway`, and `away` on presence; away people are not shown as available. The app tells the server
  when the person uses it, so a person at the keyboard does not show as away.
- **Link previews** (server D-293): `LinkCandidates` picks the first two public https links outside code; the server fetches them. A
  picture is used only from the server's own host.
- **Requests that may send null**: a request property that may be left out and may be null (`UpdateIssueRequest.assigneeId`) is
  generated as a double optional, so "leave it" and "clear it" are different things to send.

Not done, each blocked or deliberate: followed threads (the contract bundle has the schemas but no endpoint for
`/followed-threads`, and the generator never takes a wire fact by hand); PDF attachments use Quick Look's own viewer.
