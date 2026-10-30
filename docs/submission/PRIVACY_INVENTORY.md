# Privacy inventory and App Privacy answers

First written 2026-10-27 against `origin/main` 2addf20 plus the branches below, then re-checked on 2026-10-27 against `origin/main` e48ddb5, where all of them have merged. Line citations are as of e48ddb5.

| Branch | PR | Merged in |
|---|---|---|
| `claude/submission-release-layout` | #29 | f8a204d |
| `claude/submission-account-deletion` | #31 | 6a0bf62 |
| `claude/submission-post-uploads` | #33 | a79bac0 |
| `claude/submission-moderation` | #32 | 4612182 |
| `claude/submission-privacy-docs` | #34 | 67bc562 |
| `claude/submission-definer-review` | #36 | 4fa4b15 |
| `claude/submission-consent-age` (terms and minimum age) | #37 | 9c62c85 |

Paths below are relative to:
- `native/ios/Packages/PullUpKit/Sources/` for Swift code
- `supabase/migrations/` for SQL

Swift was not compiled in this environment. Nothing was read from or written to a hosted Supabase project.

> **Do not publish the App Privacy label yet.** Publish it only when both of these are true:
> 1. ~~The moderation (#32), post upload (#33), account deletion (#31) and terms tracks have merged.~~ Done: all are on `main` (table above).
> 2. This inventory has been re-checked against the merged `main` (done, e48ddb5) **and the build that will be submitted** (still open, section 4).
>
> The re-check found no change to the declared data types. It added two records from the terms track (terms acceptances and the age-check outcome, 1.1), which fall under Other Data Types, and updated report retention (1.7). Section 4 lists what is still open.

## 0. Summary

- **No tracking, so no ATT prompt.**
  - Nothing is linked with third-party data for advertising, and nothing goes to a data broker.
  - There is no ad, analytics, attribution or crash SDK.
  - The app never calls `ATTrackingManager`, never reads `advertisingIdentifier`, and never reads `identifierForVendor` (`git grep`, no matches).
  - `NSPrivacyTracking` is false with no tracking domains. Do not add tracking.
- **eBay link.** The parts link carries only search keywords and, when configured, a per-build EPN campaign id (`PullUpDomain/Parts.swift:210-235`).
  - It has no `customid`, account id or device id, and it opens in Safari.
  - This is not tracking under Apple's definition.
- **Every collected type** is linked to the account, not used for tracking, and used for App Functionality only.
  - No data is used for Analytics, Product Personalization, Developer Advertising or Third-Party Advertising.
  - The feed is reverse-chronological. "Following" is a filter of accepted followees plus me, with no ranking (`PullUpData/SupabaseBackend.swift:371-384`).
- **Owner's findings, checked in code. All five confirmed:**
  1. **The social graph is "Contacts".** There is no address-book access.
  2. **Follows are stored** in `public.follows`, `20261016000100_core_identity.sql:97`.
  3. **Likes and other interactions are stored:** `likes` (social.sql:38), `message_reactions`, `meet_rsvps`, read state.
  4. **Derived driving statistics are uploaded.** `drives` holds distance, speeds, times and elevation (drives.sql:12-35). `private.drive_cells` and `private.drive_scores` are derived from them on the server.
  5. **Purchase History is declared but not collected.** Pro is not offered (`native/ios/Config/Base.xcconfig:32` `PULLUP_PRO_OFFERED = NO`), so no purchase can be made. #34 removed it from the manifest.

## 1. Data inventory

Columns used in every table below:
- **Where in code:** where the app collects or sends the item.
- **Stored in:** destination.
- **Who can read:** the RLS policy or bucket policy that controls access.
- **Retention / deletion:** how long it is kept and how it is removed.
- **Apple type:** the App Store Connect category it maps to.

Every row is linked to the account and none is used for tracking, so those two columns are left out. Purpose is App Functionality throughout.

### 1.1 Identity and account

| Data | Where in code | Stored in | Who can read | Retention / deletion | Apple type |
|---|---|---|---|---|---|
| Account id (uuid), Apple `sub` | `PullUpData/SupabaseBackend.swift:34-46` (session in `SessionKeychain`); `PullUpFeatures/Auth/AppleCredentials.swift:28-54` (Apple user id in Keychain, service `app.pullup.sign-in-with-apple`) | `auth.users`, `auth.identities`; Keychain `app.pullup.session` (AfterFirstUnlockThisDeviceOnly) | Own only | Until deletion. The auth user is deleted last, and identities cascade (#31). Keychain is cleared on sign-out (`App/AppModel.swift:373-382`). | User ID |
| Email (Apple relay or real; email sign-in for review accounts) | `Auth/AuthView.swift:42` requests `.email`; `SupabaseBackend.swift:116-132` reads identities and the relay flag | `auth.users.email` | Not exposed through the public schema | Until deletion | Email Address |
| Name (Apple full name, then display name) | `AuthView.swift:42` `.fullName`; `SupabaseBackend.swift:139-149` (`claim_username`), `:171-190` | `profiles.display_name` (core_identity.sql:54) | **Every signed-in user, including for private profiles** (core_identity.sql:307-309; probe in SECURITY_RECHECK §2) | Until deletion; cascade | Name |
| Username, bio, presentation | `Auth/OnboardingView.swift`; `SupabaseBackend.swift:116-190` | `profiles`, `profile_details` (core_identity.sql:69) | Username: every signed-in user. Bio: `can_view` (core_identity.sql:314-316). | Until deletion; cascade | Other User Content |
| `profile_details.country_code` / `region_code` | No UI sets them. `Profile/ProfileView.swift:579` only passes back what exists (`SupabaseBackend.swift:181-188`). | `profile_details` | `can_view` | n/a | Not collected (no Coarse Location) |
| Terms acceptance: version accepted and when (#37) | `PullUpData/ConsentService.swift:22-24` (`accept_terms`); `Auth/ConsentGateView.swift:157-170` | `public.terms_acceptances` (20261025000400:93-98); `accepted_at` is the server's clock (:110-122) | Own rows only (:100-104). No update or delete through the API. | Deleted with the account (cascade from `profiles`) | Other Data Types |
| Minimum-age outcome (#37): meets the minimum or not, the minimum checked against, method `self_declared`, time | `ConsentService.swift:26-28` (`record_age_check`). The date of birth is used on the phone only (`PullUpDomain/Consent.swift:64-80`; `Auth/ConsentGateView.swift:92-108`) and is never sent | `private.age_checks` (20261025000400:139-146) | No client access (:147-148). The account sees its own status through `my_consent_status` (:316-345). | Deleted with the account (cascade). Not automatic otherwise. An under-minimum answer can't be raised through the API (:384-391); it sets the profile private, messages to nobody and leaves the leaderboards (:400-404), and the app offers account deletion (`ConsentGateView.swift:174-193`) | Other Data Types. **Self-declared and unverified**: it is not age assurance and does not stop a false date (:33-40) |

### 1.2 Location and drives

| Data | Where in code | Stored in | Who can read | Retention / deletion | Apple type |
|---|---|---|---|---|---|
| Raw GPS track (lat, lon, alt, speed, course, accuracy per fix) | `PullUpLocation/CoreLocationProvider.swift:42-73` (When In Use plus temporary full accuracy); upload at `SupabaseBackend.swift:318-326` | Device: `Application Support/Drives/<uuid>.json` (backup-excluded, `PullUpData/LocalDriveStore.swift:92`; file protection). Server: `drive_tracks` (drives.sql:47). | **Owner only** (drives.sql:679-684) | Until the drive or the account is deleted. The device file is removed after upload, on delete, or on account deletion. **Sign-out keeps unsent drafts.** | Precise Location |
| Shared route (redacted) | `SupabaseBackend.swift:348-361` | `drive_shared_routes` (drives.sql:55) | `can_view_drive` | Withdrawn when sharing is turned off; redacted again when zones change (drives.sql:613-657) | Precise Location |
| Privacy-zone centres | `Settings/SettingsView.swift:431-572`; `SupabaseBackend.swift:250-264` | `privacy_zones` (drives.sql:62) | Owner only (drives.sql:689-691) | Until removed or the account is deleted | Precise Location |
| Meet venue coordinates | `Meets/MeetComposerView.swift:84, 111` | `meets.lat/lon` (meets.sql:21-22), exact | `can_view_meet`; never private (meets.sql:23) | Until the meet is deleted or the host's account is deleted | Precise Location (also Other User Content) |
| Drive statistics (distance, top and average speed, times, elevation, title, vehicle) | `Drive/DriveRecorder.swift`; `SupabaseBackend.swift:311-338` | `drives` (drives.sql:12-35) | `can_view_drive`. **Every column is returned to anyone allowed to view the drive.** | Until deleted | Other Data Types |
| Explored cells, leaderboard scores | Server-derived (drive_privacy.sql:16; 20261020000300:30) | `private.drive_cells`, `private.drive_scores` | No API access. Boards show only opted-in totals. | Cascade from the drive | Other Data Types |
| Last-used vehicle preference | `Drive/DriveRecorder.swift:155` | UserDefaults `pullup.lastVehicle.<uid>` | Device only | Removed on account deletion (`Drive/DriveRecorder.swift:432`) | Not collected |

### 1.3 Garage

| Data | Where in code | Stored in | Who can read | Retention / deletion | Apple type |
|---|---|---|---|---|---|
| Vehicles, mods (make, model, year, trim, mileage, notes) | `Garage/VehicleEditorView.swift`; `SupabaseBackend.swift:268-306` | `vehicles`, `vehicle_mods` (garage.sql:6, 32) | `can_view` on the vehicle (garage.sql:103-112) | Until deleted. Deleting a vehicle turns its drives into guest drives. | Other Data Types / Other User Content |

### 1.4 Photos and videos

| Data | Where in code | Stored in | Who can read | Retention / deletion | Apple type |
|---|---|---|---|---|---|
| Photos (avatar, vehicle, post, message) | Picked with PhotosPicker (no permission needed). Re-rendered, which drops EXIF and GPS (`Garage/VehicleDetailView.swift:269-284`). | Buckets `avatars`, `vehicle-media`, `post-media`, `dm-media`, all private, signed URLs valid 1 h (storage.sql; direct_messages.sql:748-789) | avatars: every signed-in user unless blocked (storage.sql:167-172). Others follow their parent row. | Removed by the deletion function (`supabase/functions/delete-account`) and post cleanup (1.8). The in-app cache is memory-only and cleared on sign-out (`App/AppModel.swift:384-400`). | Photos or Videos |
| Post videos | Passthrough export with `metadataItemFilter = .forSharing()`; **the audio track is kept** (`Feed/PostComposerView.swift:183-205`) | `post-media` (up to 100 MB, mp4/quicktime) | Follows the post | As above | Photos or Videos. The sound is part of the user's video. The app has no microphone access and records no audio, so there is no separate Audio Data entry. |

### 1.5 Social activity and messages

| Data | Where in code | Stored in | Who can read | Retention / deletion | Apple type |
|---|---|---|---|---|---|
| Follows, follow requests | `SupabaseBackend.swift:192-222` | `follows` (core_identity.sql:97) | Both parties; counts in `get_profile` | Cascade | **Contacts** (social graph) |
| Blocks | `SupabaseBackend.swift:609-614` | `blocks` (core_identity.sql:107) | Blocker only | Cascade | Contacts |
| Posts, comments | `SupabaseBackend.swift:371-426`; `publish_post` (`:813-819`, 20261025000200) | `posts`, `comments`, `post_media` (social.sql:8-45) | `can_view_post` | Cascade, including other people's comments on the user's posts | Other User Content |
| Likes | `SupabaseBackend.swift:401-408` | `likes` (social.sql:38) | Through `can_view_post` | Cascade | Product Interaction |
| RSVPs, attendance display | `SupabaseBackend.swift:457-469` | `meet_rsvps` (meets.sql:34); `show_me` defaults to `show_event_attendance` (off) | `meet_attendees`, which respects `show_me` | Cascade | Product Interaction |
| Direct messages (text, photo, shared reference) | `SupabaseBackend.swift:491-541` | `messages`, `conversations` (direct_messages.sql:64-112) | Conversation members only (direct_messages.sql:698-736) | `dm_purge`, which needs the `dm-retention` cron job (direct_messages.sql:658-692): requests after 30 d, both-cleared, tombstones after 30 d. Account deletion removes **both sides**. | Emails or Text Messages |
| Reactions, read state, mute, hide | `SupabaseBackend.swift:543-584` | `message_reactions`, `conversation_members` | Members only. Read receipts are reciprocal (direct_messages.sql:467-484). | Cascade | Product Interaction |
| Notifications (in-app), read state | `SupabaseBackend.swift:731-743` | `notifications` (social.sql:54) | Recipient only (social.sql:556-561) | Cascade | Product Interaction |

### 1.6 Push and search

| Data | Where in code | Stored in | Who can read | Retention / deletion | Apple type |
|---|---|---|---|---|---|
| APNs device token | `native/ios/PullUp/PullUpApp.swift:28-46`, only after opt-in (`Settings/NotificationSettings.swift:51-52`); `SupabaseBackend.swift:745-751`; RPC at notification_preferences.sql:347-389 | `device_tokens` (social.sql:69) | No client read (`permission denied`, probe §2) | Unregistered on sign-out; cascade on deletion | Device ID |
| Notification preferences, privacy settings | `Settings/NotificationSettings.swift`; `SupabaseBackend.swift:234-248, 753-775` | `notification_preferences`, `privacy_settings` | Owner only | Cascade | Other Data Types |
| Profile search terms | `SupabaseBackend.swift:224-230` calls RPC `search_profiles` (`20261025000350_search_profiles.sql`); the term is in the POST body | **Nowhere.** Not in the database; not in a request URL, so not in the gateway's `request.path` / `request.search` log fields | — | Processed in real time only | **Not collected** (see 3.2) |

### 1.7 Reports and moderation

| Data | Where in code | Stored in | Who can read | Retention / deletion | Apple type |
|---|---|---|---|---|---|
| Reports and snapshots | `SupabaseBackend.swift:591-607`; `Messages/SharedCard.swift:106-192` (`ReportView`); `Profile/ProfileView.swift:368-370` (`ReportPersonView`) | `reports` (direct_messages.sql:120; 20261024000100; 20261025000310:587-611) | Staff only | **Kept when either account is deleted**: `reporter_id` and `subject_id` become null (`on delete set null`, 20261025000310:604-611) and the snapshot stays; `conversation_id` / `message_id` also become null (direct_messages.sql:124-125). Closed reports are purged a year after filing by `dm_purge` (direct_messages.sql:690; needs the `dm-retention` cron job). Open reports are kept until handled. | Other User Content |
| Moderation audit, suspensions, messaging pauses, deliveries, media purge queue | Server only | `private.moderation_audit` (20261025000310:69-87), `account_suspensions` (:203-211), `messaging_pauses` (20261025000330:21-26), `moderation_deliveries` (:617), `moderation_media_purge` (:824) | Owner and moderators | Audit: append-only with no foreign keys, so **its account ids survive account deletion** (:14-21); rows removed after 2 y. Suspensions and messaging pauses cascade with the account; lifted suspensions removed after 2 y. Deliveries removed 90 d after the report closes. Removed media held 30 d by default (`p_media_hold`, :989, 1006, 1087), then deleted from Storage. All by `moderation-worker` (`moderation_purge`, :1288-1315), which needs its cron job. | Covered by Other User Content / User ID |
| Webhook alert to the owner's endpoint | `supabase/functions/moderation-worker/index.ts:1-25`; payload in `_shared/moderation.ts` | Third-party chat or webhook the owner chooses | Owner | Ids, reasons, kinds, priorities and counts only: no content, names or account ids | No new type. **The endpoint provider is a processor; name it in privacy.md once chosen.** |

### 1.8 Server-side job records

| Data | Where in code | Stored in | Who can read | Retention / deletion | Apple type |
|---|---|---|---|---|---|
| Account-deletion job | `delete-account` function | `private.account_deletions` (20261025000110:15-23): user id, attempts, last error, pending Apple token | Service role | Deleted with the auth user (cascade) | Not a new type |
| Post upload journal | `PullUpData/PostPublisher.swift:114-119` (`FilePostUploadJournal`) | Device: `Application Support/PendingPostUploads.json` (paths and ids) | Device | Cleared at the next sign-in by `recoverInterruptedPosts` (`App/AppModel.swift:212`) | Not collected |
| Orphaned post media | `post_orphaned_media` (20261025000200:133) | `post-media` | Owner only | Removed by `post-media-cleanup` after 1 day (cron, not scheduled) | Photos or Videos |

### 1.9 Pro and App Store

| Data | Where in code | Stored in | Who can read | Retention / deletion | Apple type |
|---|---|---|---|---|---|
| Pro entitlement / App Store transactions | `Pro/ProStore.swift:75-103`; `native/ios/PullUp/StoreKitClient.swift:34` (`appAccountToken` = account id) | `entitlements`, `app_store_notifications` (pro_entitlements.sql:20, 46) | Own entitlement | **No purchase is possible while `PULLUP_PRO_OFFERED = NO`.** `start()` still reads the (empty) entitlement row. | Not collected now. **Purchase History must be added back before Pro goes on sale.** |

### 1.10 Logs, diagnostics and support

| Data | Where in code | Stored in | Who can read | Retention / deletion | Apple type |
|---|---|---|---|---|---|
| IP address, IP-derived approximate location, request path and query, auth events | Every request | Supabase edge, Postgres, function and auth logs. The auth audit log has user id, IP and user agent (supabase.com/docs/guides/auth/audit-logs, retrieved 2026-10-26 by the deletion track). The API gateway log (`edge_logs`) also holds the provider's IP-derived `cf.country`, `region` and `city`, plus `asOrganization`, `user_agent` and JWT metadata (staging schema checked 2026-10-27, see 3.2). | Project operators | Provider retention for the plan (API logs: see 3.2; Auth audit logs Free 1 h, Pro 7 d, Team 28 d, supabase.com/pricing, retrieved 2026-10-27). Not removed on deletion. | Pull Up doesn't use the IP or the derived location, so not declared as Coarse Location. **Owner decision:** the provider derives and keeps that location in logs operators can read, so decide whether to declare Coarse Location (section 4). privacy.md discloses it. |
| Diagnostics | None. No crash SDK, no MetricKit (`MXMetricManager`), no `OSLog` / `Logger` (`git grep`, no matches). | — | — | — | None. Apple's opt-in crash sharing is data Apple collects ("You are not responsible for disclosing data collected by Apple", developer.apple.com/app-store/app-privacy-details, retrieved 2026-10-27). |
| Support requests | Public GitHub issues; there is no in-app support form | GitHub | Public | GitHub's | Not collected through the app, so no Customer Support entry |
| Display preferences (theme, units, dashboard, Pro hint) | `App/ThemeStore.swift` | UserDefaults | Device only | Until the app is removed | Not collected |

## 2. Privacy defaults (facts)

| Setting | Default | Source |
|---|---|---|
| Profile visibility | **public** | core_identity.sql:60; `PullUpDomain/SocialModels.swift:314` |
| New vehicle visibility | friends | core_identity.sql:81; garage.sql:21 |
| Drive history ceiling | private | core_identity.sql:83 |
| Each drive | private | drives.sql:157; `PullUpData/LocalDriveStore.swift:32` |
| Route sharing | off | core_identity.sql:84 |
| Route endpoint trim | 400 m (min 200), plus a random 0–250 m extra kept per drive | core_identity.sql:85; 20261018000800:61 |
| Leaderboards | off | core_identity.sql:87 |
| Performance boards | off, and forbidden | 20261024000100:73-74 |
| Show me at meets | off | core_identity.sql:86 |
| Follow approval | off | core_identity.sql:89 |
| Messages from | everyone (non-followers land in Requests) | direct_messages.sql:30 |
| Read receipts | **on** (reciprocal) | direct_messages.sql:33 |
| Push categories | on | notification_preferences.sql:200-216 |
| Push message previews | off | notification_preferences.sql:214 |
| Posts | **public** | social.sql:267; `Feed/PostComposerView.swift:16` |
| Meets | **public**; can't be private | meets.sql:23 |
| Location | When In Use only, never Always. Temporary full accuracy per drive; reduced accuracy refuses to record. | `PullUpLocation/CoreLocationProvider.swift:42-57`; `Drive/DriveRecorder.swift:182-193` |

**Truthful sentence for the store description and the privacy policy.** "Private by default" is false for the account as a whole, so never use it:

> Drive history starts private, and route sharing and leaderboards start off. Profiles and posts start public, new vehicles start friends-only, and anyone can send you a message request; you can change each of these in Settings.

`docs/public/privacy.md` "What other people can see" already says this. Strings that overstate it:
- `Profile/ProfileView.swift:255` says "Your drives are private by default". That is accurate for drives.
- The core_identity.sql:223 comment says "private-by-default settings". Comment only.
- `/mnt/project-files/release/STORE_SUBMISSION.md` says "Drives are private by default". Accurate if it stays about drives.

## 3. App Store Connect answers: diff against the unpublished draft

The draft: 11 types, every one linked, none for tracking, App Functionality for each, and Contacts also marked Product Personalization.

### 3.1 Answer sheet (copy-ready)

**Do you or your third-party partners collect data from this app?** Yes.

**Do you or your third-party partners use data for tracking?** No.

Answer every type below with the same three choices:
- Linked to the user's identity: **Yes**
- Used for tracking: **No**
- Purpose: **App Functionality** only

| Type | Draft | Recommended | Reason |
|---|---|---|---|
| Name | ✓ App Functionality | **Keep** | Display name, prefilled from Apple's full name |
| Email Address | ✓ | **Keep** | Apple relay or real email; email sign-in accounts |
| Precise Location | ✓ | **Keep** | Raw tracks, shared routes, privacy zones, meet venues |
| Contacts | ✓ App Functionality + Product Personalization | **Keep; remove Product Personalization** | Follows and blocks are the social graph. They gate audiences and filter the Following feed, which is newest-first with no ranking or recommendations. Apple defines Personalization as "a list of recommended products, posts, or suggestions". Keeping it over-discloses but is not wrong; owner's call. |
| Emails or Text Messages | ✓ | **Keep** | Direct messages |
| Photos or Videos | ✓ | **Keep** | All four buckets. Videos keep sound, which is covered here. |
| Other User Content | ✓ | **Keep** | Posts, comments, bio, meets, mods, drive titles, reports and snapshots |
| User ID | ✓ | **Keep** | Account uuid, Apple `sub`, `appAccountToken` |
| Device ID | ✓ | **Keep** | APNs device token in `device_tokens`. It is a device-level id the server keeps. |
| Product Interaction | ✓ | **Keep** | Likes, reactions, RSVPs, read state, notification read state |
| Other Data Types | ✓ | **Keep** | Vehicle details, derived driving statistics, settings, terms acceptances, the self-declared age outcome |
| Search History | — | **Leave out** (see 3.2) | Profile search terms are sent in an RPC body and kept nowhere |
| Purchase History | — (not in draft) | **Leave out** | Pro is not offered. It was in the old manifest, and #34 removed it. **Add it back in the same release that turns Pro on.** |
| Coarse Location | — | Leave out | Nothing sets country or region, and IP addresses are not used to locate people |
| Audio Data | — | Leave out | No microphone; a video's sound is part of Photos or Videos |
| Customer Support | — | Leave out | Support is on public GitHub, outside the app |
| Crash, Performance, Other Diagnostic Data | — | Leave out | No diagnostics are collected. Apple's own crash sharing is not the developer's to disclose. |
| Health, Fitness, Financial, Sensitive Info, Browsing History, Advertising Data | — | Leave out | Not collected |

### 3.2 Search History

Not collected, since #34.
- **Before:** profile search was a GET whose query string carried the term. Supabase's API gateway logs keep `request.path` and `request.search` with the client IP, and can be filtered by JWT subject. Sources: `supabase.com/docs/guides/observability/log-field-reference` and `supabase.com/docs/guides/platform/logs`, both retrieved 2026-10-27. Those logs are kept for 1–90 days depending on plan, which would have made search terms "collected" under Apple's definition.
- **Now:** `public.search_profiles(p_prefix)` (`supabase/migrations/20261025000350_search_profiles.sql`) is a security-invoker RPC called through `client.rpc`, which sends its arguments in a POST body. Supabase's log field reference lists no request-body field for the gateway.
  - Same columns, RLS and 20-result limit as before. LIKE wildcards in the term are now literal.
  - Rollback: `supabase/rollback/20261025000350_search_profiles_down.sql`.
  - Test: `supabase/tests/036_search_profiles.sql`.
- **Caveats:**
  - Builds from before this change still send the GET until people update. The first App Store build includes the change, so this matters only for TestFlight builds.
  - **Staging checked, production open.** On 2026-10-27 the staging project's API gateway log (`edge_logs`, last 24 h, 5 records) was queried through the Supabase connector. The logged attribute keys hold `request.url`, `path` and `method`, request headers (`content_length`, `content_type`, `user_agent`, `accept`, `cf_connecting_ip`), `cf.country`, `region`, `city`, `asOrganization` and `colo`, JWT role, issuer and expiry, and the response status. There is no request-body field, so a term sent in a POST body isn't logged. Production had no traffic yet. Repeat the check there once it does; if bodies appear, declare Search History.

### 3.3 Mismatches found (old manifest, docs, code)

1. **Old manifest declared Purchase History** although Pro is not offered. Fixed in #34.
2. **Old manifest was missing three types:** Contacts, Product Interaction and Other Data Types. Fixed in #34. The ASC draft already has them.
3. **Old manifest comments were wrong:**
   - Email said Apple-only.
   - "photos" left out videos.
   - UserDefaults was said to hold "recovery state", which is actually JSON files.
   - Fixed in #34.
4. **Required-reason API: file timestamps.**
   - supabase-swift v2.55.5 (latest 2.x on 2026-10-27; the app pins `.upToNextMajor(from: "2.20.0")`) calls `FileManager.attributesOfItem` in `Sources/Storage/MultipartFormData.swift:247`.
   - That release ships no privacy manifest of its own.
   - #34 added `NSPrivacyAccessedAPICategoryFileTimestamp` / `C617.1` (files inside the app container).
   - **Now pinned:** `native/ios/Package.resolved` and `native/ios/Packages/PullUpKit/Package.resolved` are committed. They pin supabase-swift 2.55.5, the version checked above, plus swift-asn1, swift-clocks, swift-concurrency-extras, swift-crypto, swift-http-types and xctest-dynamic-overlay.
   - **Not verified:** the required-reason APIs of those transitive packages. **Owner:** run Xcode ▸ Organizer ▸ the archive ▸ Generate Privacy Report on the submitted archive and reconcile it (`docs/RELEASE_CHECKLIST.md:153-157`).
5. **The manifest is described in two other docs.** Resolved: `docs/RELEASE_CHECKLIST.md:150` and `docs/TESTFLIGHT_SETUP.md:97-100` now say there is no purchase history and no search history.
6. **`NSLocationWhenInUseUsageDescription` was too narrow.** Resolved: `native/ios/PullUp/Info.plist:38-39` now gives the proposed text, which covers the privacy-zone editor (`Settings/SettingsView.swift:523`) and the meet composer (`Meets/MeetComposerView.swift:84`) showing `UserAnnotation()`. `Drive/StartDrivePicker.swift:325` says the same.
7. **Permission denied keeps the app usable.**
   - Location denied or reduced: StartDrivePicker shows a notice with Open Settings (`Drive/StartDrivePicker.swift:290-300`). Map, zones and meets fall back to a default region.
   - Push denied: Settings button (`Settings/NotificationSettings.swift:137-150`).
   - Photos: PhotosPicker needs no permission.
   - There are no camera, microphone, contacts or motion strings, which is correct.
8. **CarPlay.**
   - `PullUp-CarPlay.entitlements` claims `carplay-driving-task`, but the shipping build uses `PullUp.entitlements` (`Base.xcconfig:40`).
   - #29 removed the CarPlay scene from Info.plist.
   - Nothing CarPlay is claimed in privacy.md or the store text.
   - `aps-environment` is `development` in the entitlements file; Xcode re-signs it as production for App Store builds.
9. **Push previews.** `NotificationSettings` says previews show "the first line of a message" (`Settings/NotificationSettings.swift:113`), but the server sends up to 120 characters with whitespace collapsed (`supabase/functions/_shared/push.ts`). Minor copy fix in the app; no owner track.
10. **Who can see what on a private profile.** A private profile still shows username, display name and avatar to every signed-in user and in search (core_identity.sql:307-309; storage.sql:167-172). That was undisclosed, and is now in privacy.md.
11. **Drive columns.** Anyone allowed to view a drive receives every column, including top speed. Leaderboards forbid speed boards, but a friends-visible drive still shows its top speed. This is intended (the summary shows it) and it is now covered in privacy.md under statistics.
12. **Terms acceptances and the age-check outcome were undisclosed.** #37 added `public.terms_acceptances` and `private.age_checks` (1.1). The terms disclosed them (`docs/public/terms.md:9, 13`), but privacy.md, this inventory and the manifest comment didn't, and privacy.md still said age restrictions "must be reflected… before public launch". Fixed in this PR: privacy.md describes both records and what an under-13 answer does, says the answer is self-declared and unverified, and the Other Data Types comment names them.
13. **The moderation audit keeps account ids after deletion.** privacy.md said reports are kept without the account's identifier but didn't say the audit record keeps them. Fixed in this PR, together with the cron caveat on moderation retention.
14. **IP-derived location in provider logs.** The gateway log holds an approximate location derived from the IP (1.10). privacy.md now says so. Whether that makes Coarse Location "collected" is an owner decision (section 4).

## 4. Release gate

Before publishing the label:
1. ~~#31, #32 and #33 (and the terms track) have merged.~~ Done (#37 is the terms track).
2. ~~This inventory has been re-checked against the merged `main`.~~ Done against e48ddb5. Re-check against the submitted build.
3. ~~Package.resolved is committed~~ (done). **Open:** the Xcode privacy report has been generated and reviewed.
4. **Open:** the moderation webhook provider is named in privacy.md.
5. **Open:** the cron jobs (`dm-retention`, `finish-deletions`, `moderation-worker`, `post-media-cleanup`) are scheduled on the project that ships (`docs/SUPABASE_SETUP.md` step 5).
6. **Open:** privacy.md confirms, in the present tense, that Supabase and Apple give equal protection (Guideline 5.1.1(i)); it still says "before production launch".
7. **Open:** the production API gateway log has been checked for request bodies (3.2).
8. **Open:** the owner has decided on Coarse Location for the IP-derived location in provider logs (1.10).
9. **Open, in App Store Connect:** Contacts is entered as App Functionality only (3.1).

The retention text in privacy.md depends on the jobs in item 5; privacy.md says so where it describes them.
