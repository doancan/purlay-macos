# Requirements: Purlay for macOS

> Last updated: 2026-11-26 · Vision: [vision.md](vision.md) · Behaviour in detail: [features/client-behaviour.md](features/client-behaviour.md)
>
> Extracted from the code, the README and the changelog on adoption; every FR is shipped. The model's behaviour is tested in
> `purlay-swift` (`Tests/PurlayKitTests`, written `Kit:`); views are tested here (`Packages/PurlayUI/Tests`, written `UI:`). `—` means no automated test.

## Functional requirements

| ID | Requirement | Acceptance (Given / When / Then) | Priority | Status | Test |
|----|-------------|----------------------------------|----------|--------|------|
| FR-001 | Sign in through the system browser; the session lives in the Keychain | Given no session, when the person signs in at the server's page and it redirects to `purlay://auth`, then the app holds a session until sign-out; given they close the browser, then no failure is shown | MVP | Done | Kit: `HandoffTests`, `SessionCookieTests`, `ServerAddressTests`, `KeychainSessionStoreTests`, live `LiveSignInTests`; UI: `PurlayUITests` (a closed sign-in has no words), snapshot of the sign-in page |
| FR-002 | Refuse a server the app cannot read, and say why | Given a server older than 0.5.0, an unsupported contract, or a newer minimum client, when the app connects, then it stops with the reason | MVP | Done | Kit: `HandshakeTests`; UI: `PurlayUITests` (every problem with a server says what it is) |
| FR-003 | Channels, direct messages, messages, threads and reactions | Given a workspace, when the person opens a channel, then its messages show with threads beside them and reactions they can add from 217 standard emoji with search in English and Turkish and recents | MVP | Done | Kit: `ChannelFeatureTests`, `ChatStateTests`, `ChannelWindowTests`; UI: `ReactionEmojiTests`, snapshot of the signed-in window |
| FR-004 | Realtime with replay, and a durable outbox | Given a connection that drops, when it returns, then the client replays from its cursors and misses nothing; given a send while offline, then it is kept across a relaunch and retried, and a failed send shows with Retry | MVP | Done | Kit: `ConnectionTests`, `ConnectionReplayTests`, `OutboxStoreTests`, `SendCoordinatorTests`, live `LiveSocketTests` |
| FR-005 | Inbox with All, Mentions, DMs and Threads filters, and unread | Given a server that advertises type filters, when the person picks Threads, then replies and resolutions load from the server; given one that does not, then filtering is local; Mark All Read changes only visible rows | MVP | Done | Kit: `InboxTests`, `InboxModelTests` |
| FR-006 | Open Topics: unresolved conversations across the workspace | Given unresolved threads, when the person opens Open Topics, then they list with channel filter, paging and Resolve, and opening a row goes to its thread without marking the channel read | Later | Done | — (Q: no test found) |
| FR-007 | Deep Work | Given a focus session, when it is on, then interruptions are quiet, and when it ends the person returns to what needs them | MVP | Done | Kit: `DeepWorkTests` |
| FR-008 | Saved messages, and drafts | Given a saved message, when the person completes, archives or restores it, then the state changes on every device; an unfinished message is a draft they can return to | MVP | Done | Kit: `SavedListTests`, `SavedPinnedTests`, `DraftsTests` |
| FR-009 | Search with channel and author filters and recents | Given filters, when the person pages through results, then every page keeps the filters; recents keep theirs per server, account and workspace and can be cleared | MVP | Done | Kit: `SearchModelTests` |
| FR-010 | Scheduled messages, with Send Now | Given a server with `scheduledMessages`, when the person schedules after uploads finish, then it is confirmed once across retries and the draft clears only then; Send Now sends it | Later | Done | Kit: `ScheduledTests` |
| FR-011 | Reminders | Given a server with `messageReminders`, when the person picks Remind Me, then a private reminder is set, listed, changeable and cancellable, and a macOS notification carries a deep link and no message content | Later | Done | Kit: `ReminderTests`; the system notification is by hand |
| FR-012 | Issues and Updates | Given a workspace whose server runs the module, when the person opens Issues or the inbox's Updates tab, then they list with loading, empty and failed states; an unknown module's notice is only read | Later | Done | Kit: `IssuesTests`, `InboxUpdatesTests`, `ModulesTests`; UI: snapshots of both |
| FR-013 | Organize the sidebar | Given custom groups, when the person adds, renames, reorders or removes one, then conversations keep their membership and the server keeps the groups | Later | Done | Kit: `SidebarTests`, `SidebarLayoutTests` |
| FR-014 | Conversation windows | Given a conversation, when opened in its own window, then it has its own navigation, thread and search while sharing one socket and outbox; closing it leaves the session running | Later | Done | Kit: `ConversationWindowTests` |
| FR-015 | App links | Given `purlay://open?url=…` or a pasted permalink, when it is opened, then the matching workspace opens after sign-in; an inaccessible or foreign-server link shows an error; a newer link supersedes a pending one | Later | Done | Kit: `ConversationLinkTests` |
| FR-016 | Settings, profile editing and workspace-aware administration | Given a role, when the person opens Settings, then owners and admins see workspace pages, owners see data, members see device and account settings, and a server admin sees Server Settings; changing name, title, status and time zone saves to the server | Later | Done | Kit: `SettingsPageTests`, `ProfileTests`; UI: snapshot of the profile editor |
| FR-017 | Tell the person what needs them: Dock badge and notices | Given activity while the window is not in front, when there is something new, then a badge and a notice show, permission is asked the first time, and the notice never carries message content | MVP | Done | Kit: `AttentionTests`, `AttentionModelTests`; the permissions are by hand |
| FR-018 | Update in place | Given a newer release, when the person checks (or automatic checks run), then Sparkle verifies the signed feed, notes and archive before extraction and installs | MVP | Done | — (only the release workflow signs and verifies; TD-004) |
| FR-019 | English and Turkish | Given a Mac set to Turkish, when the app runs, then every string is Turkish; a string without a final Turkish value fails the check | MVP | Done | `scripts/localize --check` |
| FR-020 | Appearance and accessibility | Given Reduce Transparency, Increase Contrast, Reduce Motion, or the Liquid Glass switch off, then the app draws solid, high-contrast, still; text and the hover stay readable in light and dark | MVP | Done | UI: `NativePaletteTests`, `TokenBindingTests`, `FloatingPanelTests` |
| FR-021 | Slash commands in the message box | Given `/me`, `/shrug`, `/mute`, `/unmute`, `/star`, `/unstar`, `/invite`, `/leave`, `/deepwork` or `/search`, then a list follows the typing and the command runs; `//text` sends a message that starts with a slash | Later | Done | Kit: `SlashCommandTests` |
| FR-022 | A workspace whose server has chat off still opens | Given a server with chat off, when the workspace opens, then it offers profile, members, invitations and data pages in the browser, hides the chat menus, and says chat is off for a conversation link | Later | Done | UI: snapshot (a workspace without chat); Kit: `ConversationLinkTests` (the link says chat is off) |
| FR-023 | A person at the keyboard is not shown as away | Given the app in front, when the person uses it, then the server is told, rationed to one word at a time; an app in the background starts no work of its own | MVP | Done | Kit: `AwayTests`, `IdleBudgetTests` |
| FR-024 | Delete a message for me, or for everyone | Given a server with `personalMessageDeletion`, when the person chooses, then Delete for Me hides it everywhere for them only, and Delete for Everyone follows the server's rule; failures keep the message | Later | Done | Kit: `PersonalDeletionTests` |
| FR-025 | Followed threads | Given followed threads, when the person opens them, then they list | Maybe | Blocked: the contract has no endpoint | — |

## Non-functional requirements

| ID | Area | Applies? | Target | Verification |
|----|------|----------|--------|--------------|
| NFR-PERF | Performance budget | Yes | Idle: at most two timers (the heartbeat and its watchdog) and no HTTP request in ten minutes; a window not in front starts no work of its own | Kit: `IdleBudgetTests`, which block rather than warn |
| NFR-SEC | Security | Yes | No password in the app; sandbox with exactly the allowlisted entitlements, declared and signed; strict App Transport Security in Release; signed and notarized releases; Ed25519-signed update feed, notes and archive; no secret in the history | `scripts/verify app`, `scripts/verify security`, the release workflow |
| NFR-PRIV | Privacy | Yes | A notice never carries what was said; reminders carry a deep link and no content; local state is scoped by server, account and workspace | `UI: PurlayUITests`; Kit: `AttentionTests` |
| NFR-A11Y | Accessibility | Yes | A label on every control; the system's type; Reduce Transparency, Increase Contrast and Reduce Motion followed | `UI: NativePaletteTests`; by hand with VoiceOver |
| NFR-I18N | i18n / l10n | Yes | English and Turkish complete, same format specifiers | `scripts/localize --check` |
| NFR-OBS | Observability | No | The app writes no log of its own (no `Logger`, `print` or `NSLog` in `App/` or `PurlayUI`); a person's report is the channel | grep, on adoption |
| NFR-OFF | Offline / sync | Yes | Unsent messages survive a relaunch; replay from cursors after a reconnect loses nothing | Kit: `OutboxStoreTests`, `ConnectionReplayTests` |
| NFR-REC | Recovery | Yes | A failed load says so and offers Try Again; a send that failed stays with Retry; a lost session is found on return | Kit: `LoadFailureTests`; UI: snapshot of a channel that could not be loaded |
| NFR-VER | Versioning / compatibility | Yes | Reads servers from 0.5.0; speaks contract server 0.8.0; macOS 26 floor; one `purlay-swift` pin in two files | `HandshakeTests`, `scripts/enforcement` |
| NFR-COST | Cost | No | No server cost: a client | — |
| NFR-SCALE | Scale | No | A single person's session | — |

## Assumptions

| ID | Assumption | Basis | Impact | Status |
|----|------------|-------|--------|--------|
| A-001 | The hosted service at purlay.app is the only server release builds talk to | Changelog 0.3.0, `ServerAddress.hosted` | High | Confirmed by the code; the intent is Q-003 |
| A-002 | The maintainer is the only owner | `CODEOWNERS` | Low | Confirmed |

## Open questions

| ID | Question | Owner | Target | Answer / decision |
|----|----------|-------|--------|-------------------|
| Q-001 | Why Apple Silicon only, and why a macOS 26 floor rather than lower? ([ADR 0003](../decisions/0003-platform-floor-and-architecture.md) records the fact, not the weighing.) | maintainer | — | |
| Q-002 | The code cites sections and milestones of a plan that is not in the repository (TD-001). Should its rules become ADRs, or the citations simply go? | maintainer | — | |
| Q-003 | Is sign-in at purlay.app only permanent, or will self-hosted servers return? It decides whether the server-address code stays. | maintainer | — | |
| Q-004 | What does success look like, in numbers and by when (adoption, retention)? | maintainer | — | |
| Q-005 | Should Open Topics (FR-006) get a test? None was found. | maintainer | — | |

## Out of scope

- Hosting or administering a server (opened in the browser instead).
- Intel Macs; macOS before 26.
- Followed threads, until the contract has an endpoint; PDF attachments use Quick Look's own viewer.
