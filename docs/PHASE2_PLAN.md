# Phase 2 plan

Phase 2 builds on PR #2 (`claude/native-ios-85igsc`). It is developed on
`claude/pull-up-phase-2` with its own draft PR based on that branch, so
PR #2 stays reviewable on its own. Each milestone lands as its own commits
with tests, CI evidence and screenshots, recorded in `docs/PROGRESS.md`.

Product order stays: driving first, community second, parts discovery third.

## Phase 0 audit (done before new work)

* PR #2 head: CI green for iOS and backend (links in `PROGRESS.md`).
* Everything on the demo backend is labelled; nothing has run against a
  hosted Supabase project; nothing has run on a physical iPhone.
* Defects found in the audit and fixed in M1/M5 rather than PR #2, because
  they touch Phase 2 code paths:
  * `device_tokens` is keyed by token with an owner-only policy, so when a
    second account signs in on the same phone the token can't be
    re-registered (RLS rejects the upsert). Fixed with a security-definer
    `register_device_token` RPC that moves the token (M5).
  * Accounts created with Sign in with Apple get a generated
    `driver_xxxxxxxxxx` username and are never asked to choose one. Fixed by
    first-run onboarding (M1).
  * Email sign-up asks the user to invent a password, which the brief rules
    out for iOS (M1).

## Milestones

| # | Milestone | Depends on | External blockers (work continues around them) |
| --- | --- | --- | --- |
| M1 | Apple-first sign-in, onboarding, account | — | Apple Services ID + key in Supabase to test end to end |
| M2 | Direct messages + contextual sharing | M1 (blocks, profiles) | Hosted Supabase for Realtime; APNs key for push |
| M3 | Pull Up Pro (StoreKit 2) | M1 | App Store Connect products, paid-apps agreement, App Store Server API key |
| M4 | Smart parts finder | Garage | eBay Buy API approval; optional EPN campaign ID |
| M5 | Notification preferences and push hygiene | M2 | APNs key |
| M6 | Security assessment | M1–M5 | Staging Supabase project for live testing |
| M7 | Screenshots, design pass, release docs | all | — |

### M1 — Authentication and account

* Sign in with Apple stays native (`AuthenticationServices`) with a SHA-256
  nonce verified by Supabase. It becomes the only way to create an account
  on iOS. Email sign-up is removed from the UI; email sign-in remains behind
  "Other sign-in options" for the App Review demo account, and can be turned
  off with an Info.plist flag once Apple sign-in is verified.
* Hide My Email: the relay address is stored only by Supabase Auth, never
  shown publicly; nothing in the app keys on email.
* First-run onboarding: choose username (checked live with an
  `is_username_available` RPC; uniqueness enforced by the unique index and a
  `claim_username` RPC that sets `profiles.onboarded_at`), optional photo,
  privacy defaults (drive history, route sharing, follow approval, DM
  requests).
* Apple credential revocation: check `getCredentialState` on launch and
  listen for `credentialRevokedNotification`; revoked → sign out locally
  with an explanation.
* Account deletion stays server side (`delete-account`), now also revoking
  the Apple token when the Apple client secret is configured (documented
  remaining action otherwise).
* Android later: Google sign-in. Account linking design in
  `ARCHITECTURE.md`: a signed-in user links a second provider via Supabase
  identity linking; never auto-merge on matching email.

### M2 — Direct messages

* Tables: `conversations` (exactly two members, canonical pair key so one
  conversation per pair), `conversation_members` (state: active / request /
  hidden, last read, mute), `messages` (text, optional photo, optional shared
  object), `message_reactions`, `reports`. Private storage bucket
  `dm-media` readable only by members.
* Rules in Postgres: send only as yourself, only to conversations you belong
  to, never while either side has blocked the other; first message from
  someone the recipient doesn't follow lands as a request; recipients
  control read receipts (`privacy_settings.dm_read_receipts`) and who may
  message them (`everyone` / `people I follow`); per-sender rate limits
  (messages per minute, new conversations per day) enforced by trigger.
* Shared objects reference vehicles, posts, meets or drives by id and are
  re-checked with the existing `can_view_*` functions when read, so sharing
  never widens visibility. A drive share never carries a route or GPS.
* Client: inbox with unread counts, requests tab, thread with pagination,
  delivery states (sending / sent / failed with retry), reactions, photo
  messages (EXIF stripped), "Message owner" from a vehicle, share sheet from
  posts, meets, drives and vehicles. Realtime via Supabase channels; the
  demo backend simulates replies so it can be tested in CI.

### M3 — Pull Up Pro

* StoreKit 2 with a local `PullUpPro.storekit` configuration (monthly
  $3.99, yearly $29.99, both placeholders pending product-owner approval)
  used by tests; no live products are created.
* Free forever: speedometer and recording, garage, social, DMs, meets,
  privacy and safety. Nothing free today becomes paid.
* Pro: extra speedometer faces, extra accent palettes, drive analytics
  (speed distribution, compare drives), GPX/CSV export.
* Entitlements: the app sends the signed transaction (JWS) to a
  `verify-subscription` edge function that verifies it with Apple's App Store
  Server Library and writes `entitlements` (service role only). App Store
  Server Notifications V2 update renewals, grace period, billing retry,
  refunds and revocation. The client reads its entitlement from the
  database; local StoreKit state is only a hint, so editing the client
  can't unlock server-backed features.
* Paywall states: products unavailable (unconfigured), purchasing,
  pending (Ask to Buy), success, failed, restored.

### M4 — Smart parts finder

See `MARKETPLACE_FEASIBILITY.md`. Built so it ships useful without eBay API
approval: vehicle-aware eBay search links first, Browse API results behind a
server-side proxy once approved.

### M5 — Notifications

Per-category preferences (messages, requests, reactions, followers, meets,
account/security, price alerts later) stored server side and honoured by
`send-push`; message previews off by default in push payloads; token
registration via RPC with rotation and cleanup on APNs `410`.

### M6 — Security assessment

OWASP MASVS and API Security Top 10 as checklists. Executed as pgTAP and
edge-function tests against the CI's local Supabase stack with synthetic
users; static review of the client. Findings, evidence and retests in
`SECURITY_REPORT.md`. No third-party or production systems are tested.

### M7 — Quality and release

Screenshots for every new screen in light, dark and accessibility sizes,
critical review and fixes, updated `RELEASE_CHECKLIST.md`.

## Decisions taken by default (say if you want otherwise)

* One Phase 2 branch and draft PR, stacked on PR #2.
* Email/password sign-up removed from iOS; email sign-in kept only behind
  "Other sign-in options" for review/demo accounts.
* DM requests: messages from people you don't follow arrive as requests;
  read receipts on by default and switchable; message previews in push off
  by default.
* Pro pricing is only in the local StoreKit test file until you approve it
  in App Store Connect.
