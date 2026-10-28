# Changelog

User-facing changes to Purlay for macOS. Releases require macOS 26 or later.

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
