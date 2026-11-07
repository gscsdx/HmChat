# Roadmap

Updated: 2026-10-31. The goal is feature-by-feature Telegram Web A mobile parity with native ArkUI interactions. Single-column phones and the folded wide-fold device come first. No unverified release dates or claims of full parity.

[Features](FEATURES.en.md) describes current scope; the [changelog](../CHANGELOG.en.md) records changes. The detailed [Web A matrix](TELEGRAM_WEB_PARITY.md) defines acceptance. [中文](ROADMAP.md).

## Foundation delivered

Real authentication, two-account switching, core message actions, rich display, mixed albums, progressive native video, per-account storage management, three-state appearance, source publication and the website exist with separate evidence. Their remaining boundaries are on the Features page, rather than labeling them wholly absent.

## Priorities and acceptance

| Priority | Next work | Acceptance |
| --- | --- | --- |
| P0 · Correctness | Cross-page reply/scroll anchors, full read semantics, concurrent drafts/sends, permissions/failure recovery | Real cross-client checks; no lost drafts, duplicate sends or fabricated delivery across chat/keyboard/network changes |
| P0 · Media/cache reliability | More codecs/containers, non-faststart, weak/offline networks and audio interruptions; safe upload-staging reclamation | Synthetic-device coverage; missing chunks recover, tasks stop on close; reference-aware cleanup preserves pending/retry media |
| P1 · Discovery/organization | Server global/in-chat search, archive, cloud folders, profiles/shared media | Genuine server results with correct paging/filtering/permissions and preserved navigation context |
| P1 · Complete messaging | Arbitrary files, voice/music, stickers/GIFs, selection/reactions/pinning and full replies | Web A entry, TDLib implementation, native interaction and live exchange separately accepted |
| P1 · Account completeness | Inactive synchronization/notifications; more unread/draft/file/logout isolation | Cleaning or logging out one account cannot affect another; stale updates cannot leak across accounts |
| P2 · Settings/admin | Privacy/devices, groups/channels, roles/invites/members, more download exceptions | Server-permission-driven actions and explicit scope/confirmation for sensitive changes |
| P2 · Notifications | Candidate Simple Push → Worker → HarmonyOS Push Kit | Entitlements/tokens, registration/revocation, retry, background delivery and tap-to-sync; no message body by default |
| P2 · Player enhancements | PiP, subtitles/tracks, quality selection and automatic gallery export | Implement only when platform/message capabilities exist, with independent permission/lifecycle tests |
| P3 · Other forms/accessibility | Folding transitions, rotation, tablet/large/split/free windows, large text, accessibility and languages | Keep account/chat/draft/search/scroll context; no duplicate requests or sends |
| Distribution gate | Reproducible packages, source/license/dependency records, signing/version/package checks | No private materials, release guards and notices passed, matching source and binary |

## Paused and experimental

- Cloud HAP builds in GitHub Actions remain paused. CI checks domain/public safety and deploys only the static site; no official HAP is published.
- Calls, Stories and other Web A capabilities remain in the full matrix; these groups do not narrow that scope.


## Notifications (planned)

Notification permissions, background delivery, synchronization after a tap and sign-out cleanup still require implementation and independent device validation. Offline notifications are not operational.
