# Available features

Updated: 2026-11-06. HmChat is an actively developed native third-party Telegram client for HarmonyOS NEXT. It does not yet have full Telegram Web A parity. See the [roadmap](ROADMAP.en.md), [changelog](../CHANGELOG.en.md), and detailed [Web A parity matrix](TELEGRAM_WEB_PARITY.md).

## Reading the status

Implemented means real protocol behavior and native interactions exist. Device-verified covers only the named actions and hardware. Partial means known gaps remain. Host tests, SDK builds, device launches, and server synchronization are different evidence. Current acceptance prioritizes the single-column phone and the folded wide-fold device, not every format or device.

## Capabilities and evidence

| Area | Available now | Evidence | Limits / Web A gaps |
| --- | --- | --- | --- |
| Authentication | Separate country/calling-code and phone fields; typing a calling code selects the country/region (`+1` US, `+7` Russia, `+86` China); verification code, existing two-step password and email states; registration/resend branches and 30-second errors | Two real accounts, update installs and normal restart retention; `+1`/`+7`/`+86` matching checked on the designated device | Not every registration, delivery channel or recovery case has live coverage |
| Multiple accounts | Nested account manager with avatars, add/switch, isolated credentials/database/download policies; pending logins stay private | Round trips between two accounts and cold-start/avatar retention | Only the active account connects; inactive notifications and full logout/draft/unread isolation need more coverage |
| Chats and contacts | Real chats, avatars, unread/draft previews, history paging, existing contacts, Saved Messages, pin/mute entries; complete filter bar (All/Unread/Groups/Channels) with matching empty states; supergroups classified as groups and broadcast channels as channels | Real navigation, history, drafts and avatars; all four filters shown/switched with empty states retested on the designated device; supergroup/channel classification covered by domain tests | Search/filter cover loaded data; no server search, cloud folders or complete archive; supergroup/channel display with a real account is not device-tested |
| Text and actions | Messaging/send states, reply, edit, forward, permission-aware delete and copy entry | Device/Web checks for text, reply/edit, forwarding to Saved Messages and delete-for-self | Copy not independently device-tested; precise cross-page reply navigation, full read semantics, selection/reactions and permissions remain |
| Message display | Native entities, common RichMessage blocks, group senders/avatars, grouping, dates, forwarding/reply previews | Read-only comparisons across three real groups; synthetic media regressions | Complex blocks and complete sticker/GIF/special-message handling remain incomplete |
| Photos and albums | Up to 10 system-selected photos/videos, caption/removal, album sending/grid, browsing, zoom and confirmed export | Mixed albums in both directions, standalone video, export and double-tap zoom | Originals, quality/editing/reordering, HEIF, continuous pinch and more failure cases remain |
| Video player | Native progressive AVPlayer streaming and uncached seeking/resume; ±30 seconds, seven speeds, temporary 2× hold with rate restoration, tap/double-tap/swipe, controls, mute and background pause | Cold-cache 150-second H.264/AAC MP4, remote seeks, playback through chunks to completion, 1.5×→2×→1.5× and skip controls on device | More codecs/non-faststart/weak-network/call-interruption cases, PiP, subtitles/tracks and quality switching remain |
| Storage and traffic | Per-active-account category/chat clearing, retention/cap, network-specific photo/video/animation limits, traffic totals | Real statistics, selective clearing, video re-fetch and preference retention | Maintenance requires a running process; inactive accounts, upload staging, contact exceptions and automatic gallery saving remain |
| Network proxy (mihomo) | In-app VPN switch; subscription-link and YAML import; node/group selection and latency tests; global or HmChat-only scope | Proxy domain tests plus the real core/subscription path verified on the designated device | System VPN authorization, protect fallback and background keep-alive after toggling, notifications and release-build runtime remain unverified; the GPL source bundle and third-party licenses are incomplete, so builds are not distributable |
| Native appearance | HDS titles/settings rows for settings, accounts, storage pages; original compact chat details; system menus/sheets, glass tabs, light/dark/system and safe areas | Page returns, keyboard/draft retention, appearance persistence and system-following on device | Complete accessibility, large text and every system scenario need separate validation |
| Folding and large screens | Width-based design with an unfolded two-pane static capture | Privacy-redacted device illustration | Full folding/rotation/multi-window continuity not accepted; folded form comes first |
| Offline preview | Fictional local fixtures isolated from real accounts | Domain/UI development | Local changes are not cloud delivery |

## Not yet supported

- Server global/in-chat search, cloud folders, full archive/profiles/shared media.
- Arbitrary files, complete voice/music and sticker/GIF workflows, message selection/reactions, group/channel administration.
- Background push/reliable offline alerts, calls, Stories and complete privacy/device-session management.
- PiP, subtitles/multiple tracks, quality switching and all device forms.

Notifications remain roadmap work. Do not depend on the preview for important notifications.

## Verification baseline

This batch has 534 host tests (533 pass / 0 fail / 1 skip with `PYTHONUTF8=1`), a real SDK 26 signed build, and update-install/launch evidence on the designated device. These are not full-feature acceptance. Details: [accounts](MULTI_ACCOUNT.md), [display](MESSAGE_DISPLAY.md), [media](MEDIA.md), [video](VIDEO_PLAYER.md), [storage](STORAGE_MANAGEMENT.md), [status](STATUS.md).

Public pages use reviewed assets and synthetic-test descriptions only, without private conversations, phone numbers, device serials, deployment credentials or raw screenshots.
