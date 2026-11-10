# Changelog

User-facing changes to Purlay for macOS. Releases require macOS 26 or later.

## [Unreleased]

### Fixed

- Search, the jump palette and the list sheets (Pins, Reminders, Scheduled, Saved, Drafts, Shortcuts, Browse Channels) now close when you press anywhere outside them, including the sidebar and the toolbar, or when the window loses the keyboard, instead of only with Escape.

### Improved

- An update nobody did, or whose person is gone, shows its module's symbol instead of a question mark, and a module this app has no screen for is named with a capital.
- The "could not load" notice of a channel sits lower in the window instead of against its top edge.

## [0.2.1] — 2026-11-10

The whole app in Turkish, a calmer sidebar, and a round of fixes for the things a team meets every day.

### New

- **Turkish.** Every screen, menu and message of the app is now in Turkish when your Mac is set to it, worded as the web client words it. English stays the default.
- **Keyboard.** Start typing anywhere in the conversation and the message box takes the keyboard, with what you typed. Escape from a thread or an edit puts you back in the box. **Focus Message Box** (⌘L), **Add Reaction…** (⇧⌘E) and **Resolve Thread** (⇧⌘R) are in the Message menu.

### Improved

- A calmer sidebar: its pages are lines of the sidebar, in regular weight and the system's row height, with a quiet fill for the one that is open and the accent only on its symbol.
- A workspace with no channels says so and offers Browse Channels and New Conversation, instead of "No matching channels".
- Names and channels sort in your language's order everywhere (Çağlar before Zeynep), and singular counts read right ("1 reply").
- Drafts are tracked as they change, so typing a long message no longer makes the sidebar read every channel's draft again.
- Deleting an issue, a message that could not be sent, or a saved search now asks first.
- The window can no longer be made narrower than a message and its box need.
- VoiceOver reaches the reactions, files, thread button and edit box of a message, and the buttons of a message that could not be sent.

### Fixed

- A channel or thread that could not be loaded no longer shows a loading placeholder for ever: it says so and offers Try Again.
- A sheet left open when a session ended (Saved Messages, Pins, Search, Drafts) no longer opens by itself the next time you sign in.
- New Issue no longer shares its shortcut with Open Conversation in New Window.

## [0.2.0] — 2026-11-10

Requires a Purlay server 0.5.0 or later (0.6.1 is current).

### New

- **Channel bookmarks.** Keep links at hand under the channel header, add them from the Channel menu or Channel Details, and remove them from the context menu.
- **Mark Unread and Mark All as Read.** Mark a conversation unread from any message, or catch up on every channel at once from the Go menu (⇧⎋).
- **Announcement channels.** In channels where only owners and admins post, everyone else sees a clear note in place of the composer and can still reply in threads.
- **Questions and decisions.** Mark a thread as a question, accept a reply as its answer, assign it, and record a decision with a link. Open Topics can show unanswered questions or those assigned to you.
- **Search filters and saved searches.** Filter by thread status, code or files, marked questions, repository and dates; save searches with a name, then run, rename or delete them.
- **Reaction limit.** You can put at most three different reactions on one message; Purlay says so instead of sending a fourth, and removing one makes room.
- **GitHub work and webhooks.** Issues and pull requests linked to a thread appear as chips, and messages posted by incoming webhooks show the hook's name.
- **Issues.** A native page for the workspace's issues: open and done lists, make an issue with details, give it to somebody, finish or reopen it, and delete it. Search also finds issues. It appears where the server runs the issues module.
- **Inbox updates.** A new Updates tab lists what the workspace's other modules tell you, such as an issue assigned to you, with a count of what waits. Opening one reads it and takes you to the issue.
- **Groups that follow you.** The groups in your sidebar are now kept by the server, so every Mac and the web show the same ones, and a folded group stays folded. Groups you made on this Mac are sent to the server once.
- **Set Yourself Away.** Say you are away from the account menu; people who are away no longer show as available.
- **Link previews.** A link in a message shows a card with the page's title, description and real host. Cards are fetched by your server, and a picture is shown only when your server serves it.
- **Workspaces without chat.** A workspace whose server does not run chat now says so, and offers the browser, instead of showing an empty window.

### Improved

- Clear guidance when your server requires two-step verification, and a warning when a workspace you belong to is scheduled for deletion.
- Settings explains where your display name comes from and how to change it.
- A server older than 0.5.0 is now named as too old at sign-in instead of failing later.
- Sign-in methods added by newer servers, such as Google, no longer stop the handshake.

## [0.1.1] — 2026-10-28

A more native Mac experience, with built-in updates and clearer ways to catch up.

### New

- **Built-in updates.** Check for updates from the Purlay menu and choose automatic checks in Settings. Sparkle verifies the update feed, release notes and downloaded app before installation.
- **Inbox filters.** Switch between All, Mentions, Direct Messages and Threads, alongside the unread filter. Compatible servers filter the full history; older servers filter the notifications already loaded, with Load More available.
- **More reactions.** Choose from 221 standard emoji, browse categories, search in English or Turkish, and reuse recent reactions.
- **Workspace settings.** View your profile, account details and workspace members in a native settings window. Owners and administrators get links to workspace management; invitations and role changes open in your browser. Data and history settings are reserved for owners.
- **Mac menus.** File, Message, Channel and Go menus, a useful Dock menu, and keyboard shortcuts for everyday navigation.

### Improved

- System Liquid Glass toolbar and sidebar, neutral reading surfaces, grouped message actions and clearer code blocks, attachments and links.
- Better behavior in narrow windows, with readable titles and message actions that remain inside the visible area.
- Opaque, outlined controls when Reduce Transparency or Increase Contrast is enabled, plus support for Reduce Motion.
- Server compatibility checks and capability detection, including older handshake responses.

### Fixed

- Loading older history no longer hides messages received while the request is in flight.
- Changing Inbox filters discards stale results, and Mark All Read affects only the notifications visible in the current filter.
- Sign Out Everywhere now asks for confirmation.

### Installation

- **Apple Silicon only.** This release requires an M-series Mac. Intel builds are no longer provided.
- **Upgrading from 0.1.0:** download and install 0.1.1 manually once. Version 0.1.0 does not include the updater; subsequent releases can be installed through Purlay.
- Download the ZIP from the release page, extract it and move Purlay.app to Applications. A compatible Purlay server is required.

## [0.1.0] — 2026-10-27

First public release of the native macOS client.

- Channels, direct conversations, threads, reactions and attachments.
- Inbox, saved messages, drafts, channel members and file browsing.
- Search, keyboard navigation, notifications and Deep Work.
- Developer ID signing and Apple notarization.

[0.1.1]: https://github.com/doancan/purlay-macos/releases/tag/v0.1.1
[0.1.0]: https://github.com/doancan/purlay-macos/releases/tag/v0.1.0
