# Changelog

This records source changes, not an installable HAP release. See [features](docs/FEATURES.en.md) for current scope and evidence, and the [roadmap](docs/ROADMAP.en.md) for plans. [中文](CHANGELOG.md).

## Unreleased · 2026-11-06

### Brand and entry points

- User-visible branding is now HmChat, with a new black-and-white ring icon; bundleName is now `com.hmchat.app`, installed alongside the old package with no automatic data migration. Internal `harlgram.*` storage keys and log tags are unchanged.
- The welcome screen is gone: an unauthenticated cold start opens Settings, a restored session opens Chats, and logout returns to Settings. Settings keeps the sign-in and network-proxy entries.

### Added and changed

- Settings offers 10 API presets shown only as masked `ID ****last4 / Hash ****last4`; only the selected index is persisted, and no credential values are recorded.
- The chat filter bar is a fixed All/Unread/Groups/Channels set with filter-specific empty states; supergroups count as groups and broadcast channels as channels.
- Sign-in matches the country/region from a typed calling code; `+1` US, `+7` Russia and `+86` China are verified with the country picker kept in sync.
- mihomo network proxy: in-app VPN switch, subscription-link and YAML import, node/group selection and latency tests, and global or HmChat-only scope. Proxy domain tests and the real core/subscription path are verified on the designated device.

### Validation and limitations

- `PYTHONUTF8=1 ./scripts/test-domain.sh` passes 534 tests (533 pass / 0 fail / 1 skip); real SDK 26 compilation plus signed HAP update-install and launch passed. These are not full-feature acceptance.
- System VPN authorization, protect fallback and background keep-alive after toggling, notifications and release-build runtime remain unverified; the GPL source bundle and third-party licenses are incomplete, so builds are not distributable. This remains a source preview, not a HAP release.

## Unreleased · 2026-11-01

### Changed and fixed

- HDS native titles, settings rows and button hierarchy for settings, accounts and storage pages, with improved search, selection and back navigation. AGENTS.md links the shared design guidelines.
- Chat details retain the original avatar, compact header and expandable conversation actions, preserving navigation, messages, drafts and media layout.

### Validation and limitations

- Navigation, keyboard handling and original-draft retention have designated-device evidence. Other window forms, large text and complete accessibility require separate validation.
- Website features, roadmap and bilingual changelog are regenerated together. This is a source preview, not a HAP release.

## Unreleased · 2026-10-31

### Added

- Multiple accounts, nested account manager and avatars; isolated credentials/database/media policy; unfinished logins stay out of the account list.
- Up to 10 mixed photos/videos, album sending/grids, browsing and confirmed system export.
- Progressive native video, uncached seeking/automatic resume, ±30 seconds, seven speeds and temporary 2× hold with restoration; tap/double-tap/swipe controls and background pause.
- Category/per-chat cache management, retention/caps, network-specific media limits and traffic statistics.
- Common RichMessage blocks, text entities, group avatars/grouping, forwarding and reply previews.
- Dedicated website Features, Roadmap and Changelog navigation, generated from shared bilingual Markdown.

### Fixed

- Login errors, duplicate submissions, resend/timeout handling and project branding on startup/login.
- Message-bottom following, keyboard anchors, media proportions and odd album layouts.
- Asynchronous seek/play intent races, stale progress, missing cache paths/cold starts and player-control placement/readability.
- Reactive storage settings and stale account/file-update isolation.

### Documentation and validation

- Prioritized roadmap with acceptance criteria, current capabilities separated from plans, and the detailed Web A matrix retained.
- 316 host tests, real SDK 26 signed compilation and device update-install/launch passed. Two-account, cross-client media, cold-cache video and gesture evidence is recorded separately. No claim covers every codec/device.
- API secrets, signing, sessions, databases, raw screenshots/logs and private deployment addresses remain excluded. This is a source development preview.

## Initial source publication · 2026-10-29

- Native HarmonyOS NEXT/ArkUI foundation, pinned TDLib/security integration, real authentication and basic chats/message actions.
- GPL-3.0-or-later, dependency notices, development/AI handoff docs, build/device scripts, public-file checks and redacted illustrations.
- Chinese-default/English README and static website on the default GitHub Pages domain.

Unreleased or unverified features are not retroactively labeled released; Git history is authoritative for actual merges.
