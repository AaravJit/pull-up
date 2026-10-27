# Privacy inventory and App Privacy answers

Written 2026-10-27 against `origin/main` 2addf20, plus these unmerged branches:

| Branch | Head | Draft PR |
|---|---|---|
| `claude/submission-account-deletion` | cc65af5 | #31 |
| `claude/submission-moderation` | edfd7d3 | #32 |
| `claude/submission-post-uploads` | d169c91 | #33 |
| `claude/submission-release-layout` | — | #29 |

Paths below are relative to:
- `native/ios/Packages/PullUpKit/Sources/` for Swift code
- `supabase/migrations/` for SQL

Swift was not compiled in this environment. Nothing was read from or written to a hosted Supabase project.

> **Do not publish the App Privacy label yet.** Publish it only when both of these are true:
> 1. The moderation (#32), post upload (#33), account deletion (#31) and terms tracks have merged.
> 2. This inventory has been re-checked against the merged `main` and the build that will be submitted.
>
> Each of those PRs adds or changes stored data or retention (sections 1 and 5). `docs/public/privacy.md` in this PR describes the merged state, so merge it after #31, #32 and #33.

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
  - The feed is reverse-chronological. "Following" is a filter of accepted followees plus me, with no ranking (`PullUpData/SupabaseBackend.swift:348-361`).
- **Owner's findings, checked in code. All five confirmed:**
  1. **The social graph is "Contacts".** There is no address-book access.
  2. **Follows are stored** in `public.follows`, `20261016000100_core_identity.sql:97`.
  3. **Likes and other interactions are stored:** `likes` (social.sql:38), `message_reactions`, `meet_rsvps`, read state.
  4. **Derived driving statistics are uploaded.** `drives` holds distance, speeds, times and elevation (drives.sql:12-35). `private.drive_cells` and `private.drive_scores` are derived from them on the server.
  5. **Purchase History is declared but not collected.** Pro is not offered (`native/ios/Config/Base.xcconfig:31` `PULLUP_PRO_OFFERED = NO`), so no purchase can be made. This PR removes it from the manifest.

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
| Account id (uuid), Apple `sub` | `PullUpData/SupabaseBackend.swift:33-37` (session); `PullUpFeatures/Auth/AppleCredentials.swift` (Apple user id in Keychain, service `app.pullup.sign-in-with-apple`) | `auth.users`, `auth.identities`; Keychain `app.pullup.session` (AfterFirstUnlockThisDeviceOnly) | Own only | Until deletion. The auth user is deleted last, and identities cascade (#31). Keychain is cleared on sign-out (`App/AppModel.swift:301-309`). | User ID |
| Email (Apple relay or real; email sign-in for review accounts) | `Auth/AuthView.swift:42` requests `.email`; `SupabaseBackend.swift:97-107` reads identities | `auth.users.email` | Not exposed through the public schema | Until deletion | Email Address |
| Name (Apple full name, then display name) | `AuthView.swift:42` `.fullName`; `SupabaseBackend.swift:147-166` | `profiles.display_name` (core_identity.sql:54) | **Every signed-in user, including for private profiles** (core_identity.sql:307-309; probe in SECURITY_RECHECK §2) | Until deletion; cascade | Name |
| Username, bio, presentation | `Auth/OnboardingView.swift`; `SupabaseBackend.swift:115-166` | `profiles`, `profile_details` (core_identity.sql:69) | Username: every signed-in user. Bio: `can_view` (core_identity.sql:314-316). | Until deletion; cascade | Other User Content |
| `profile_details.country_code` / `region_code` | No UI sets them. `Profile/ProfileView.swift:577` only passes back what exists. | `profile_details` | `can_view` | n/a | Not collected (no Coarse Location) |

### 1.2 Location and drives

| Data | Where in code | Stored in | Who can read | Retention / deletion | Apple type |
|---|---|---|---|---|---|
| Raw GPS track (lat, lon, alt, speed, course, accuracy per fix) | `PullUpLocation/CoreLocationProvider.swift:42-73` (When In Use plus temporary full accuracy); upload at `SupabaseBackend.swift:295-306` | Device: `Application Support/Drives/<uuid>.json` (backup-excluded, file protection). Server: `drive_tracks` (drives.sql:47). | **Owner only** (drives.sql:679-684) | Until the drive or the account is deleted. The device file is removed after upload, on delete, or on account deletion. **Sign-out keeps unsent drafts.** | Precise Location |
| Shared route (redacted) | `SupabaseBackend.swift:325-338` | `drive_shared_routes` (drives.sql:55) | `can_view_drive` | Withdrawn when sharing is turned off; redacted again when zones change (drives.sql:613-657) | Precise Location |
| Privacy-zone centres | `Settings/SettingsView.swift:433-559`; `SupabaseBackend.swift:227-241` | `privacy_zones` (drives.sql:62) | Owner only (drives.sql:689-691) | Until removed or the account is deleted | Precise Location |
| Meet venue coordinates | `Meets/MeetComposerView.swift:83` | `meets.lat/lon` (meets.sql:21-22), exact | `can_view_meet`; never private (meets.sql:23) | Until the meet is deleted or the host's account is deleted | Precise Location (also Other User Content) |
| Drive statistics (distance, top and average speed, times, elevation, title, vehicle) | `Drive/DriveRecorder.swift`; `SupabaseBackend.swift:288-311` | `drives` (drives.sql:12-35) | `can_view_drive`. **Every column is returned to anyone allowed to view the drive.** | Until deleted | Other Data Types |
| Explored cells, leaderboard scores | Server-derived (drive_privacy.sql:16; 20261020000300:30) | `private.drive_cells`, `private.drive_scores` | No API access. Boards show only opted-in totals. | Cascade from the drive | Other Data Types |
| Last-used vehicle preference | `Drive/DriveRecorder.swift:155` | UserDefaults `pullup.lastVehicle.<uid>` | Device only | Removed on account deletion (#31) | Not collected |

### 1.3 Garage

| Data | Where in code | Stored in | Who can read | Retention / deletion | Apple type |
|---|---|---|---|---|---|
| Vehicles, mods (make, model, year, trim, mileage, notes) | `Garage/VehicleEditorView.swift`; `SupabaseBackend.swift:245-267` | `vehicles`, `vehicle_mods` (garage.sql:6, 32) | `can_view` on the vehicle (garage.sql:103-112) | Until deleted. Deleting a vehicle turns its drives into guest drives. | Other Data Types / Other User Content |

### 1.4 Photos and videos

| Data | Where in code | Stored in | Who can read | Retention / deletion | Apple type |
|---|---|---|---|---|---|
| Photos (avatar, vehicle, post, message) | Picked with PhotosPicker (no permission needed). Re-rendered, which drops EXIF and GPS (`Garage/VehicleDetailView.swift:269-284`). | Buckets `avatars`, `vehicle-media`, `post-media`, `dm-media`, all private, signed URLs valid 1 h (storage.sql; direct_messages.sql:748-789) | avatars: every signed-in user unless blocked (storage.sql:167-172). Others follow their parent row. | Removed by the deletion function (#31) and post cleanup (#33). The in-app cache is memory-only after #31. | Photos or Videos |
| Post videos | Passthrough export with `metadataItemFilter = .forSharing()`; **the audio track is kept** (`Feed/PostComposerView.swift:168-173`) | `post-media` (up to 100 MB, mp4/quicktime) | Follows the post | As above | Photos or Videos. The sound is part of the user's video. The app has no microphone access and records no audio, so there is no separate Audio Data entry. |

### 1.5 Social activity and messages

| Data | Where in code | Stored in | Who can read | Retention / deletion | Apple type |
|---|---|---|---|---|---|
| Follows, follow requests | `SupabaseBackend.swift:168-198` | `follows` (core_identity.sql:97) | Both parties; counts in `get_profile` | Cascade | **Contacts** (social graph) |
| Blocks | `SupabaseBackend.swift:601-606` | `blocks` (core_identity.sql:107) | Blocker only | Cascade | Contacts |
| Posts, comments | `SupabaseBackend.swift:363-418`; `publish_post` (#33) | `posts`, `comments`, `post_media` (social.sql:8-45) | `can_view_post` | Cascade, including other people's comments on the user's posts | Other User Content |
| Likes | `SupabaseBackend.swift:393-418` | `likes` (social.sql:38) | Through `can_view_post` | Cascade | Product Interaction |
| RSVPs, attendance display | `SupabaseBackend.swift:424-461` | `meet_rsvps` (meets.sql:34); `show_me` defaults to `show_event_attendance` (off) | `meet_attendees`, which respects `show_me` | Cascade | Product Interaction |
| Direct messages (text, photo, shared reference) | `SupabaseBackend.swift:483-533` | `messages`, `conversations` (direct_messages.sql:64-112) | Conversation members only (direct_messages.sql:698-736) | `dm_purge`, which needs the cron job (direct_messages.sql:658-692): requests after 30 d, both-cleared, tombstones after 30 d. Account deletion removes **both sides**. | Emails or Text Messages |
| Reactions, read state, mute, hide | `SupabaseBackend.swift:535-581` | `message_reactions`, `conversation_members` | Members only. Read receipts are reciprocal (direct_messages.sql:467-484). | Cascade | Product Interaction |
| Notifications (in-app), read state | `SupabaseBackend.swift:722-734` | `notifications` (social.sql:54) | Recipient only (social.sql:556-561) | Cascade | Product Interaction |

### 1.6 Push and search

| Data | Where in code | Stored in | Who can read | Retention / deletion | Apple type |
|---|---|---|---|---|---|
| APNs device token | `native/ios/PullUp/PullUpApp.swift:28-46`; RPC at notification_preferences.sql:347-389 | `device_tokens` (social.sql:69) | No client read (`permission denied`, probe §2) | Unregistered on sign-out; cascade on deletion | Device ID |
| Notification preferences, privacy settings | `Settings/NotificationSettings.swift`; `SupabaseBackend.swift:211-225, 744-765` | `notification_preferences`, `privacy_settings` | Owner only | Cascade | Other Data Types |
| Profile search terms | `SupabaseBackend.swift:200-206` calls RPC `search_profiles` (`20261025000350_search_profiles.sql`); the term is in the POST body | **Nowhere.** Not in the database; not in a request URL, so not in the gateway's `request.path` / `request.search` log fields | — | Processed in real time only | **Not collected** (see 3.2) |

### 1.7 Reports and moderation

| Data | Where in code | Stored in | Who can read | Retention / deletion | Apple type |
|---|---|---|---|---|---|
| Reports and snapshots | `SupabaseBackend.swift:583-599`; `Messages/SharedCard.swift:108-184`; `Profile/ProfileView.swift:368` | `reports` (direct_messages.sql:120; 20261024000100) | Staff only | On main, cascade-deleted with either account. With #32, kept with ids set to null; closed reports are purged after 1 y by `dm_purge` (cron); open reports are kept until handled. | Other User Content |
| Moderation audit, suspensions, deliveries, media purge queue (**#32, pending**) | Server only | `private.moderation_audit`, `account_suspensions`, `moderation_deliveries`, `moderation_media_purge` | Owner and moderators | Audit 2 y; lifted suspensions 2 y; deliveries 90 d after close; removed media held 30 d (`moderation_purge`, #32 migration 20261025000310:1288-1310) | Covered by Other User Content / User ID |
| Webhook alert to the owner's endpoint (**#32**) | `moderation-worker` | Third-party chat or webhook the owner chooses | Owner | Ids, reasons, kinds, priorities and counts only: no content, names or account ids | No new type. **The endpoint provider is a processor; name it in privacy.md once chosen.** |

### 1.8 Server-side job records (pending merges)

| Data | Where in code | Stored in | Who can read | Retention / deletion | Apple type |
|---|---|---|---|---|---|
| Account-deletion job (**#31, pending**) | `delete-account` function | `private.account_deletions` (#31 migration 20261025000110): user id, attempts, last error, pending Apple token | Service role | Deleted with the auth user (cascade) | Not a new type |
| Post upload journal (**#33, pending**) | `FilePostUploadJournal` | Device: `Application Support/PendingPostUploads.json` (paths and ids) | Device | Cleared at the next sign-in by `recoverInterruptedPosts` | Not collected |
| Orphaned post media (**#33**) | `post_orphaned_media` | `post-media` | Owner only | Removed by `post-media-cleanup` after 1 day (cron, not scheduled) | Photos or Videos |

### 1.9 Pro and App Store

| Data | Where in code | Stored in | Who can read | Retention / deletion | Apple type |
|---|---|---|---|---|---|
| Pro entitlement / App Store transactions | `Pro/ProStore.swift:75-103`; `native/ios/PullUp/StoreKitClient.swift:34` (`appAccountToken` = account id) | `entitlements`, `app_store_notifications` (pro_entitlements.sql:20, 46) | Own entitlement | **No purchase is possible while `PULLUP_PRO_OFFERED = NO`.** `start()` still reads the (empty) entitlement row. | Not collected now. **Purchase History must be added back before Pro goes on sale.** |

### 1.10 Logs, diagnostics and support

| Data | Where in code | Stored in | Who can read | Retention / deletion | Apple type |
|---|---|---|---|---|---|
| IP address, request path and query, auth events | Every request | Supabase edge, Postgres, function and auth logs. The auth audit log has user id, IP and user agent (supabase.com/docs/guides/auth/audit-logs, retrieved 2026-10-26 by the deletion track). | Project operators | Provider retention: API and DB as above; Auth audit logs Free 1 h, Pro 7 d, Team 28 d (supabase.com/pricing, retrieved 2026-10-27). Not removed on deletion. | Not used to derive location, so not Coarse Location. The logs contain only types already declared. |
| Diagnostics | None. No crash SDK, no MetricKit (`MXMetricManager`), no `OSLog` / `Logger` (`git grep`, no matches). | — | — | — | None. Apple's opt-in crash sharing is data Apple collects ("You are not responsible for disclosing data collected by Apple", developer.apple.com/app-store/app-privacy-details, retrieved 2026-10-27). |
| Support requests | Public GitHub issues; there is no in-app support form | GitHub | Public | GitHub's | Not collected through the app, so no Customer Support entry |
| Display preferences (theme, units, dashboard, Pro hint) | `App/ThemeStore.swift` | UserDefaults | Device only | Until the app is removed | Not collected |

## 2. Privacy defaults (facts)

| Setting | Default | Source |
|---|---|---|
| Profile visibility | **public** | core_identity.sql:60; `PullUpDomain/SocialModels.swift:314` |
| New vehicle visibility | friends | core_identity.sql:81; garage.sql:21 |
| Drive history ceiling | private | core_identity.sql:83 |
| Each drive | private | drives.sql:157; `PullUpData/LocalDriveStore.swift:96` |
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
| Posts | **public** | social.sql:267; `Feed/PostComposerView.swift:113` |
| Meets | **public**; can't be private | meets.sql:23 |
| Location | When In Use only, never Always. Temporary full accuracy per drive; reduced accuracy refuses to record. | `PullUpLocation/CoreLocationProvider.swift:42-57`; `Drive/DriveRecorder.swift:182-193` |

**Truthful sentence for the store description and the privacy policy.** "Private by default" is false for the account as a whole, so never use it:

> Drive history starts private, and route sharing and leaderboards start off. Profiles and posts start public, new vehicles start friends-only, and anyone can send you a message request; you can change each of these in Settings.

`docs/public/privacy.md` "What other people can see" already says this. Strings that overstate it:
- `Profile/ProfileView.swift:253` says "Your drives are private by default". That is accurate for drives.
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
| Other Data Types | ✓ | **Keep** | Vehicle details, derived driving statistics, settings |
| Search History | — | **Leave out** (see 3.2) | Profile search terms are sent in an RPC body and kept nowhere |
| Purchase History | — (not in draft) | **Leave out** | Pro is not offered. It was in the old manifest, and this PR removes it. **Add it back in the same release that turns Pro on.** |
| Coarse Location | — | Leave out | Nothing sets country or region, and IP addresses are not used to locate people |
| Audio Data | — | Leave out | No microphone; a video's sound is part of Photos or Videos |
| Customer Support | — | Leave out | Support is on public GitHub, outside the app |
| Crash, Performance, Other Diagnostic Data | — | Leave out | No diagnostics are collected. Apple's own crash sharing is not the developer's to disclose. |
| Health, Fitness, Financial, Sensitive Info, Browsing History, Advertising Data | — | Leave out | Not collected |

### 3.2 Search History

Not collected, as of this PR.
- **Before:** profile search was a GET whose query string carried the term. Supabase's API gateway logs keep `request.path` and `request.search` with the client IP, and can be filtered by JWT subject. Sources: `supabase.com/docs/guides/observability/log-field-reference` and `supabase.com/docs/guides/platform/logs`, both retrieved 2026-10-27. Those logs are kept for 1–90 days depending on plan, which would have made search terms "collected" under Apple's definition.
- **Now:** `public.search_profiles(p_prefix)` (`supabase/migrations/20261025000350_search_profiles.sql`) is a security-invoker RPC called through `client.rpc`, which sends its arguments in a POST body. Supabase's log field reference lists no request-body field for the gateway.
  - Same columns, RLS and 20-result limit as before. LIKE wildcards in the term are now literal.
  - Rollback: `supabase/rollback/20261025000350_search_profiles_down.sql`.
  - Test: `supabase/tests/036_search_profiles.sql`.
- **Caveats:**
  - Builds from before this change still send the GET until people update. The first App Store build includes the change, so this matters only for TestFlight builds.
  - Whether the gateway logs bodies wasn't checked against a live project, only against Supabase's documented fields. If a later check finds bodies in logs, declare Search History.

### 3.3 Mismatches found (old manifest, docs, code)

1. **Old manifest declared Purchase History** although Pro is not offered. Fixed in this PR.
2. **Old manifest was missing three types:** Contacts, Product Interaction and Other Data Types. Fixed in this PR. The ASC draft already has them.
3. **Old manifest comments were wrong:**
   - Email said Apple-only.
   - "photos" left out videos.
   - UserDefaults was said to hold "recovery state", which is actually JSON files.
   - Fixed in this PR.
4. **Required-reason API: file timestamps.**
   - supabase-swift v2.55.5 (latest 2.x on 2026-10-27; the app pins `.upToNextMajor(from: "2.20.0")`) calls `FileManager.attributesOfItem` in `Sources/Storage/MultipartFormData.swift:247`.
   - That release ships no privacy manifest of its own.
   - This PR adds `NSPrivacyAccessedAPICategoryFileTimestamp` / `C617.1` (files inside the app container).
   - **Not verified:** the other transitive packages, and which supabase-swift version Xcode resolves.
   - There is no `Package.resolved` in the repo, so every CI build can resolve a different 2.x. **Owner/release-layout:** commit `Package.resolved`, then run Xcode ▸ Product ▸ Archive ▸ Generate Privacy Report on the submitted archive.
5. **The manifest is described in two other docs, and they are now stale.** `docs/RELEASE_CHECKLIST.md:128-131` and `docs/TESTFLIGHT_SETUP.md:56-60` list the old set (with purchase history). Both files are edited by #29, so release-layout owns them: point them at this file instead of repeating the list.
6. **`NSLocationWhenInUseUsageDescription` is too narrow.** At `native/ios/PullUp/Info.plist:38-39` it says location is used "only while you record a drive". But the privacy-zone editor (`Settings/SettingsView.swift:499-511`) and the meet composer (`Meets/MeetComposerView.swift:83`) show `UserAnnotation()` once permission has been granted.
   - Proposed text: "Pull Up uses your location while you record a drive, to measure speed, distance, elevation and your route, and to show where you are when you place a meet or a protected place on the map."
   - #29 edits this Info.plist (it removes the CarPlay scene) but not this key. **Owner: release-layout.**
   - `Drive/StartDrivePicker.swift:314-318`, "Location is only used while a drive is recording.", needs the same change.
7. **Permission denied keeps the app usable.**
   - Location denied or reduced: StartDrivePicker shows a notice with Open Settings (`Drive/StartDrivePicker.swift:281-294`). Map, zones and meets fall back to a default region.
   - Push denied: Settings button (`Settings/NotificationSettings.swift:137-150`).
   - Photos: PhotosPicker needs no permission.
   - There are no camera, microphone, contacts or motion strings, which is correct.
8. **CarPlay.**
   - `PullUp-CarPlay.entitlements` claims `carplay-driving-task`, but the shipping build uses `PullUp.entitlements` (`Base.xcconfig:37-39`).
   - On main, Info.plist still declares a CarPlay scene, which #29 removes.
   - Nothing CarPlay is claimed in privacy.md or the store text.
   - `aps-environment` is `development` in the entitlements file; Xcode re-signs it as production for App Store builds.
9. **Push previews.** `NotificationSettings` says previews show "the first line of a message", but the server sends up to 120 characters with whitespace collapsed (`supabase/functions/_shared/push.ts`). Minor copy fix in the app; no owner track.
10. **Who can see what on a private profile.** A private profile still shows username, display name and avatar to every signed-in user and in search (core_identity.sql:307-309; storage.sql:167-172). That was undisclosed, and is now in privacy.md.
11. **Drive columns.** Anyone allowed to view a drive receives every column, including top speed. Leaderboards forbid speed boards, but a friends-visible drive still shows its top speed. This is intended (the summary shows it) and it is now covered in privacy.md under statistics.

## 4. Release gate

Before publishing the label:
1. #31, #32 and #33 (and the terms track) have merged.
2. This inventory has been re-checked against the merged `main`.
3. Package.resolved is committed and the Xcode privacy report has been reviewed.
4. The moderation webhook provider is named in privacy.md.
5. The cron jobs (`dm-retention`, `finish-deletions`, `moderation-worker`, `post-media-cleanup`) are scheduled on the project that ships.

The retention text in privacy.md depends on those jobs.
