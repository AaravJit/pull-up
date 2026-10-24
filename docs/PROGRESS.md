# Progress

Native iOS rebuild of Pull Up. Phases 1 to 3 are merged into `main`
(Phase 1 and 2 through PR #2 and PR #3, Phase 3 through PRs #4 to #21).
The Expo app at the repository root is unchanged.

## Phase 3

Plan and milestone order: `PHASE3_PLAN.md`. Nothing has run on a real
device, Apple's servers or eBay unless a row says so. The hosted staging
project has (`STAGING_DEPLOYMENT.md`), see the Staging row.
Device checks: `DEVICE_TEST_PLAN.md`, failures reported with the **Device
test result** issue template. No physical-device test has been run yet.

| Milestone | Work | Status | Evidence / remaining action |
| --- | --- | --- | --- |
| M1 | Two-account API tests over the full local stack (auth, REST, realtime, storage, edge functions) | Working (local stack in CI) | `supabase/tests/api/two_accounts_test.ts`, 13 areas, green in backend CI on `f3d9d18` |
| M1 | Staging and production deploy workflow with a destructive-migration guard | Set up for staging, no run completed | On `main`; runs only when started by hand. The `staging` GitHub environment has `SUPABASE_PROJECT_REF` (variable), `SUPABASE_ACCESS_TOKEN` and `SUPABASE_DB_PASSWORD` (secrets). First run (from `main`, `bc124d8`) failed at the migration-list step: GitHub's runners have no IPv6 and the direct database host is IPv6-only; PR #22 connects through the IPv4 session pooler. Second run (from #22's branch, 2026-10-24) was refused before any step ran: `staging` only allows deployments from `main`. #22 merged 2026-10-24. Remaining: run Supabase deploy ▸ `staging` from `main`, a dry run first, then with apply ticked (`STAGING_DEPLOYMENT.md` step 7). No production project exists yet |
| M1 | Hosted staging (`pull-up-staging`) | Deployed, through the Supabase connector | 24 migrations (all on `main`) applied through the connector, last on 2026-10-20; 5 edge functions, 4 buckets; pgTAP files 001–014, 262 of 262 (2026-10-20), 015 not run there yet; two-account API checks 133 of 133 (2026-10-18). Dashboard: sign-up hook, redirect URL and Apple provider done 2026-10-23 (owner), not verified end to end; other steps still open: `STAGING_DEPLOYMENT.md` |
| M2 | Public email and phone sign-ups refused on the server (Apple only) | Working (local stack in CI) / enabled on staging, not verified end to end | Auth hook, migration `20261018000100`; pgTAP `007`; API test "nobody can register with email from outside". Hook enabled on staging 2026-10-23 (owner, dashboard). `public.hook_before_user_created(jsonb)` exists there and only `supabase_auth_admin` can execute it (checked 2026-10-24 by SQL). That a public sign-up is refused there hasn't been checked yet (`STAGING_DEPLOYMENT.md` step 1) |
| M2 | Live Sign in with Apple | Needs a signed build and a device | Apple provider configured on staging 2026-10-23 (owner, dashboard), not verified end to end. Native sign-in needs the bundle ID in the provider's Client IDs (`SUPABASE_SETUP.md` step 5); the owner confirmed it is there on 2026-10-24 |
| M5 | Per-account rate limit on `verify-subscription` (10 a minute, 60 an hour) | Working (local stack in CI) | Migration `20261018000200`; API test calls it 12 times. Pro state comes only from the server's entitlement; local StoreKit state never grants it |
| M5 | Pro prices ($3.99 a month, $29.99 a year) | Proposed; Pro deferred | Pro is hidden unless `PULLUP_PRO_OFFERED = YES` or the account already has Pro (#20). Not set up in App Store Connect; no products exist |
| M4 | Messages recover after going offline: channel rebuilt with backoff, chats and inbox reload on reconnect and on returning to the foreground | Working (local stack in CI) / app side unverified on a device | API test takes a client offline and checks the reload and resumed delivery; `DEVICE_TEST_PLAN.md` D4.3–D4.4 |
| M1 | Build label for the staging backend | Working | Settings ▸ About shows "Pull Up server (staging)" when `PULLUP_BACKEND_ENVIRONMENT = staging` |

### TestFlight (M9)

Each stage is tracked on its own. `TESTFLIGHT_SETUP.md` has the steps.

| Stage | Status | Evidence / remaining action |
| --- | --- | --- |
| Unsigned Release archive | Passing | CI builds it on pull requests that touch the app |
| Signed archive | Not done | Needs the Apple account steps in `TESTFLIGHT_SETUP.md` §1–4 |
| Upload accepted by App Store Connect | Not done | Needs a signed archive |
| App Store Connect processing finished | Not done | Needs an accepted upload |
| Installed on a device from TestFlight | Not done | Needs a processed build |

### Physical-device tests passed

One row per test from `DEVICE_TEST_PLAN.md` that passed on a real iPhone.
Failures go in issues (**Device test result** template), not here.

| Test ID | Build | iOS | Device | Date | Notes |
| --- | --- | --- | --- | --- | --- |

None yet.

## Phase 2

Plan: `PHASE2_PLAN.md`. Status uses the legend below. Nothing in Phase 2 has
run on a real device, against Apple's servers or with eBay; those steps are
in `RELEASE_CHECKLIST.md` §4a and §6. Its migrations and functions are on
the hosted staging project, where their pgTAP files and the two-account API
checks passed (`STAGING_DEPLOYMENT.md`).

| Milestone | Feature | Status | Evidence / remaining action |
| --- | --- | --- | --- |
| M1 | Sign in with Apple first, onboarding (username, photo, privacy), email behind "Other ways to sign in" | Working (demo data) / needs Apple | UI tests `testSignedOutShowsAuth`, `testNewAccountOnboarding` (screenshots 28–33); real Apple sign-in needs a device |
| M1 | No account merge on matching email; explicit linking only | Working (backend) | pgTAP `002_accounts.sql`; trigger confirmed installed on staging (`STAGING_DEPLOYMENT.md`), production pending (checklist §1) |
| M1 | Apple revocation sign-out, deletion with token revocation | Needs Apple | `APPLE_*` secrets (checklist §4a) |
| M2 | One-to-one messages: inbox, requests, read receipts, photos, reactions, unsend, report, block, sharing | Working (demo data), rules enforced in backend | pgTAP `003_direct_messages.sql` (44); UI `testDirectMessages` (34–40). Realtime not yet run against a live server |
| M3 | Pull Up Pro paywall, Ring face, Papaya/Acid accents, speed-band analytics, GPX/CSV export | Working (demo store, no payment) | `ProFlowTests`, UI `testProSubscription` (41–44) |
| M3 | StoreKit 2 purchase, Ask to Buy, expiry | Working (local StoreKit file only) | `PullUpStoreTests`; no products exist in App Store Connect |
| M3 | Server-verified entitlements | Working (backend, Apple stubbed) | pgTAP `004` (20), Deno tests; never called Apple's real API |
| M4 | Parts finder: vehicle-aware eBay search links, no listings | Working | `PartsTests`, UI `testPartsFinderBuildsAVehicleSearch` (45). No eBay API access; listings need eBay approval |
| M5 | Per-category push preferences, previews off by default, token rotation, push-tap routing | Working (backend, demo UI) / needs Apple for delivery | pgTAP `005` (24), Deno `push_test.ts`, `PushFlowTests`, UI tests (46–47) |
| M6 | Security assessment | Done for the local stack and staging | `SECURITY_REPORT.md`; pgTAP `006` (20); 4 database fixes; Phase 3 re-check fixes applied to staging, pgTAP passed there |
| M7 | Phase 2 screens in dark mode and Accessibility L | Working | UI tours (48–57) |

Phase 2 CI, green on `99f9b66`: [iOS run 39](https://github.com/AaravJit/pull-up/actions/runs/39005443175)
(package tests, app build, 15 UI journeys on iOS 26.5, `PullUpStoreTests`
on iOS 26.2 because of Apple FB22237318) and [backend run 27](https://github.com/AaravJit/pull-up/actions/runs/39005443166)
(pgTAP `001`–`006`, rollbacks, Deno tests). Screenshots 01–57:
[`ci/screenshots/claude-pull-up-phase-2`](https://github.com/AaravJit/pull-up/tree/ci/screenshots/claude-pull-up-phase-2).

## Evidence

* iOS workflow, green: package tests on the simulator, app build, 7 UI
  journeys and 28 screenshots. [Run 17](https://github.com/AaravJit/pull-up/actions/runs/38973216396)
  on `6cd2e6c`, iPhone 17 Pro simulator, iOS 26.5, Xcode 26.6.
* Backend workflow, green: real local Supabase stack, pgTAP privacy and RLS
  suite, lint, every migration rolled back and re-applied, edge functions
  type-checked. [Run 7](https://github.com/AaravJit/pull-up/actions/runs/38973222071).
* Screenshots of every major screen, regenerated on every push:
  [`ci/screenshots/claude-native-ios-85igsc`](https://github.com/AaravJit/pull-up/tree/ci/screenshots/claude-native-ios-85igsc).

## Feature report

Legend:

* **Working**: implemented end to end and exercised by automated tests on
  CI (unit tests on the package, UI tests on the simulator, or pgTAP on a
  real Postgres).
* **Demo data**: the screen is real, but in CI and screenshots it runs on the
  labelled in-memory `DemoBackend`. It is never shown without the "Demo data"
  strip.
* **Needs backend**: the client and the server code both exist and the
  server side is tested, but it only runs against a live Supabase project
  once `Secrets.xcconfig` is filled in (see `RELEASE_CHECKLIST.md`). The
  server side is on hosted staging and tested there through its APIs
  (`STAGING_DEPLOYMENT.md`); no app build has used it yet.
* **Needs device / Apple**: can't be verified in a simulator, or needs an
  entitlement or key only the Apple Developer account holder can create.

| Area | Feature | Status | Evidence / remaining action |
| --- | --- | --- | --- |
| Drive | Start Drive picker reads the garage, preselects the last choice, supports guest | Working | `DriveRecorderTests`, UI test `testDriveIsRecordedAgainstThePickedVehicle` |
| Drive | Picker never requests location until Start is confirmed | Working | `doesNothingUntilAVehicleIsConfirmed`; UI test asserts no dashboard after opening |
| Drive | Empty garage: add vehicle or drive as guest | Working | `testEmptyGarageOffersAddOrGuest` |
| Drive | Accessibility text sizes switch the picker to a list | Working | `testLargeTextPickerUsesList` |
| Drive | Picker dismiss (close button, drag down) without recording | Working | `testPickerCanBeDismissedWithoutRecording` |
| Drive | Drive is logged to the chosen vehicle and shows in its history | Working (demo data) | Unit test checks `vehicleID` on the uploaded row; UI test finds the new drive on the vehicle page |
| Drive | Live dashboard: speed, distance, time, avg/top, elevation, 0–60 EST | Working on replayed GPS | UI test records ~40 s of a replayed real-time track. Real GPS: needs device |
| Drive | Background recording, precise-location prompt, stationary handling | Needs device | `CoreLocationProvider` compiles in CI but needs real GPS; checklist §6 |
| Drive | Too-short drives rejected; offline save and retry; crash recovery | Working (unit) | `DriveRecorderTests`, `DataTests`; real offline/crash: needs device |
| Drive | Summary: map, charts, title/audience edit, share trimmed route | Working (demo data) | Screenshots 06–07. Server-side trimming: pgTAP |
| Telemetry | Fix filtering, moving time, top speed median, 0–60 interpolation, gaps | Working | 24 Swift Testing cases in `PullUpTelemetryTests` |
| Garage | Cars and motorcycles, body silhouettes, identity colours, reorder, archive, delete | Working (demo data) | Screenshots 08–09, 22; `GarageStore` unit tests |
| Garage | Per-vehicle visibility enforced server side | Working (backend) | pgTAP `001_privacy_and_rls.sql` |
| Garage | Photo upload with EXIF stripped, mods list | Needs backend | Upload path uses Supabase Storage; EXIF check: needs device |
| Feed | Following / discover feed, likes, comments, posts with photos and video | Demo data / needs backend | Screenshot 14, 26. Uploads need a live project |
| Meets | List by day, detail, RSVP going/interested, opt-in "show me" | Working (demo data) | `testBrowseEveryArea`, screenshots 18–20 |
| Meets | Create meet with map-placed venue, host cancel | Needs backend | Not covered by UI tests |
| Map | Meets on map, your own routes layer; never live positions | Demo data | Screenshot 13 |
| Leaderboards | Driving boards, closed-course boards gated to verified track days | Working (backend) / demo data in UI | pgTAP covers gating; screenshots 11–12 |
| Profile | Layouts, featured vehicle, accent, follow/unfollow, editor | Demo data | Screenshot 15 |
| Settings | Appearance, accent, speedometer, units, dashboard tiles | Working (device-local) | Screenshots 16, 23–26 |
| Settings | Privacy toggles, privacy zones | Demo data in UI, enforced in backend | pgTAP checks zone redaction |
| Account | Email sign-in (review and staff accounts; the app has no email sign-up), email confirmation link | Needs backend | `pullup://auth-callback` handled; added as a redirect URL on staging 2026-10-23, not verified end to end |
| Account | Sign in with Apple | Needs Apple | Bundle ID in Supabase ▸ Auth ▸ Apple ▸ Client IDs (checklist §3); provider configured on staging 2026-10-23, not verified end to end |
| Account | Delete account (server side) | Needs backend | `delete-account` edge function; exercised on staging through the API (5 deletion and 2 clean-up checks, 2026-10-18) |
| Notifications | In-app list and unread badge | Demo data | Bell on Drive tab |
| Notifications | APNs push | Needs Apple | `send-push` function; APNs key + webhook (checklist §1, §3) |
| CarPlay | Driving-task scene: status, choose vehicle, start, stop | Needs Apple | Compiles in CI; entitlement request (`CARPLAY.md`) |
| Backend | Schema, RLS, anti-spoofing validation, route redaction | Working | Backend workflow: pgTAP, lint, rollback and re-apply of every migration |
| Backend | Reversible migrations that refuse to destroy data | Working | Rollbacks guarded by `pullup.allow_destructive_rollback` |
| Android | Kotlin client | Not started | Domain/Telemetry rules are written to port directly |

## What "demo data" means here

`DemoBackend` holds fictional people, cars, meets and drives. Their drive
statistics are produced by the real telemetry engine from synthetic tracks, so
the numbers are internally consistent, but none of it is real. It is used
only by previews, UI tests, screenshots, and an explicit "Explore with demo
data" button on builds without server keys.

## Design review

Every screen was reviewed from the simulator screenshots CI publishes to the
`ci/screenshots` branch (folder `claude-native-ios-85igsc`). Found and fixed:

| Found | Fix |
| --- | --- |
| Live dashboard and empty-garage picker: inner accessibility identifiers were overridden by the container's, so two UI journeys failed | Containers use `.accessibilityElement(children: .contain)` |
| Tab bar floated over the bottom of the picker | Hidden while the picker is open, as it already was while recording |
| Demo strip filled the status bar; in dark mode the white clock sat on light amber | Strip starts below the status bar; shorter copy that wraps at accessibility sizes |
| Segmented controls hyphenated "MOTORCY-CLES" and "COMMU-NITY"; body-style grid did the same | Single line with tightening and scale-down |
| Settings speedometer previews were squeezed: scale labels collided, the tape numeral escaped its card, the digital numeral truncated to dots | Previews render at dashboard size and scale down |
| Map tab rendered blank in the simulator, then framed the whole coast (or the world) instead of the meets | Flat map style; the map is inserted after its content loads and framed with a camera distance, which doesn't depend on the tab's size. It no longer shows the device location at all |
| Picker panel stretched to full height with dead space around the cards | Carousel sizes to its content, so the panel hugs it |
| Picker list at accessibility sizes printed the model year as "1,994" and repeated it | Verbatim text; subtitle shows type and body instead |
| Drive summary in demo mode said "Verified by server" although no server ran | Demo shows "Demo · not server-checked"; real builds show the server's verdict |
| Screen titles crowded the strip above them | Extra top spacing on screen titles |
| Start button at accessibility sizes truncated to "START RECOR…" | Cluster buttons may wrap and scale |

Still open:

* MapKit tiles depend on network in CI; a run with no tile access shows a
  grid (the app is not at fault).
* The analog needle springs, so a mid-motion screenshot can show it a few
  mph off the arc.
* Tertiary ink is below 4.5:1 in light mode (see `DESIGN.md`) and is kept to
  non-essential metadata.

## Known gaps

* No production Supabase project yet. On staging, some dashboard steps in
  `STAGING_DEPLOYMENT.md` are still open: manual identity linking, the
  function secrets, the push webhook and the daily DM clean-up job (they
  need the `pg_net` and `pg_cron` extensions), and a completed deploy
  workflow run.
* No snapshot tests; visual review is done from CI screenshots.
* App icon is a generated placeholder gauge.
