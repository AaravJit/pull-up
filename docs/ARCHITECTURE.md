# Pull Up architecture

Pull Up is a native iOS app (Swift 6, SwiftUI, iOS 18+) on a Supabase
backend. The original Expo prototype at the repository root is untouched; the
native app lives in `native/ios/` (Expo's `.gitignore` reserves `/ios` for its
own prebuild output).

```
native/ios/
  project.yml              XcodeGen spec; the .xcodeproj is generated, never committed
  Config/                  Base.xcconfig (committed) + Secrets.xcconfig (gitignored)
  PullUp/                  App shell: entry point, CarPlay scene, Info.plist, assets
  PullUpUITests/           End-to-end journeys that also capture screenshots
  PullUpStoreTests/        App-hosted StoreKit tests against a local .storekit file
  Packages/PullUpKit/      Everything else, as a local Swift package
  scripts/                 CI helpers (simulator picker, readable xcodebuild output)
supabase/
  migrations/              Forward migrations (7 from Phase 1, 5 from Phase 2)
  rollback/                Matching down migrations, destructive steps guarded
  tests/                   pgTAP suites: RLS, privacy, accounts, messages, Pro, push, security
  functions/               Edge functions: delete-account, send-push (APNs), dm-retention,
                           verify-subscription, app-store-notifications; _shared/ has Deno tests
```

## Module layering

Lower layers never import higher ones.

| Module | Depends on | Holds |
| --- | --- | --- |
| `PullUpDomain` | Foundation | Wire models (snake_case `CodingKeys` mirror the schema), units, audiences |
| `PullUpTelemetry` | Domain | GPS sample filter, drive statistics engine, 0–60 detector, route simplification and redaction |
| `PullUpData` | Domain, Telemetry, supabase-swift | `BackendService` protocol, `SupabaseBackend`, `DemoBackend`, offline `LocalDriveStore` |
| `PullUpLocation` | Domain | `LocationProvider` protocol, `CoreLocationProvider`, `ReplayLocationProvider` |
| `PullUpDesign` | Domain | "Cluster" design system: tokens, primitives, speedometers, vehicle silhouettes |
| `PullUpFeatures` | all of the above | Screens and view models, `AppModel`, `DriveRecorder`, `GarageStore` |

Domain and Telemetry are pure Swift with no Apple UI frameworks, so their
rules (sample rejection thresholds, moving-time hysteresis, 0–60
interpolation, haversine) can be ported line for line to the Kotlin Android
client. The wire contract is the Postgres schema plus the RPCs in
`supabase/migrations`; both clients talk to the same PostgREST API.

## State

`AppModel` (`@MainActor @Observable`) is created once by the app and holds:

* the backend (`SupabaseBackend`, `DemoBackend`, or `UnconfiguredBackend`
  when the build has no keys),
* the auth phase,
* `ThemeStore` (appearance, accent, speedometer, units, dashboard tiles; device-local),
* `GarageStore`, the single source of the user's vehicles,
* `DriveRecorder`, the single recorder.

`AppModel.shared` exists only so the CarPlay scene drives the same recorder as
the phone UI.

## Recording a drive

```
Start Drive button ──► StartDrivePicker ──(confirm)──► DriveRecorder.start(with: vehicle?)
                         reads GarageStore                │
                         preselects remembered choice     ├─ asks LocationProvider for permission (first time only)
                         no location access               ├─ writes DriveDraft (crash-safe) to LocalDriveStore
                                                          └─ consumes AsyncStream<LocationEvent>
                                                                │
                              TelemetryEngine.ingest(sample) ◄──┘  rejects bad fixes, accumulates stats
                              LiveTelemetry (1 Hz tick) ──────────► LiveDashboardView
Hold to stop ──► DriveRecorder.finish()
                   summary → Drive(vehicleID: chosen id or nil) → BackendService.upload(drive, track)
                   on failure the draft stays on disk and syncPending() retries on next launch/sign-in
```

* Opening the picker never touches location. Permission is requested inside
  `start(with:)`, which only the picker's Start button (or CarPlay) calls.
* The chosen vehicle ID is stored on the draft, the uploaded `drives` row
  and therefore the vehicle's history. `nil` means a guest drive.
* The last choice (vehicle or guest) is remembered per user in
  `UserDefaults`; a deleted vehicle falls back to the first one.
* `CLLocationUpdate.liveUpdates(.automotiveNavigation)` provides fixes. A
  `CLBackgroundActivitySession` exists only while recording, so recording
  continues in the background with When-In-Use permission (the blue pill
  shows) and Always is never requested. `CLServiceSession` with a temporary
  full-accuracy purpose key asks for Precise Location if it was turned off.
* `.stationary` events (iOS pausing updates at a light) are rendered as a
  known zero speed, not as signal loss.
* Drives under 30 clean fixes or 200 m are discarded with an explanation;
  the server rejects them anyway.

The recorder is covered by `PullUpFeaturesTests/DriveRecorderTests.swift`
(vehicle association end to end into the backend, guest drives, remembered
choice, permission refusal, approximate location, too-short drives), and the
UI test `testDriveIsRecordedAgainstThePickedVehicle` drives the real picker,
records a replayed track, stops, and checks the drive is listed under the
picked vehicle.

## Measurement honesty

* Speeds come from Doppler (`CLLocation.speed`); a speed derived from
  position deltas is marked as derived and rendered dimmer.
* Top speed is the median of three consecutive good readings, so a single
  spike can't become a record.
* 0–60 is always labelled an estimate (`EST`). At ~1 Hz GPS the interpolated
  time is indicative only, and it never feeds a leaderboard.
* Distance across a signal gap is bridged with a straight line, counted
  separately and disclosed on the summary.
* Altitude is marked as an estimate.

## Backend security model

All authorization is in Postgres row-level security; the client is not a
security boundary.

* `private.can_view(owner, visibility)` decides every read: owner, then
  blocks, then public / friends (mutual accepted follows) / private, with
  the owner's profile visibility as a ceiling.
* Private vehicles, drives and posts are unreachable to anyone else through
  any table, RPC, computed field or storage path (pgTAP tests assert this).
* Raw drive tracks live in `drive_tracks`, readable by the owner only.
  Shared routes are generated server side by `private.build_shared_route`:
  points inside privacy zones plus 150 m are dropped, the configured trim
  plus a random 0–250 m is cut from each end, points are thinned to 25 m and
  rounded to four decimals.
* Server-owned columns (validation status, verified organizer, computed
  stats) are protected by triggers; only `private.is_trusted()` roles may set
  them.
* `private.validate_drive` re-derives distance and top speed from the stored
  track and rejects or flags inconsistent uploads (non-monotonic time,
  distance mismatch over 25%, top speed absent from the track, implausible
  speeds, overlapping drives, uniform accuracy, flat altitude).
* Performance leaderboards (0–60, top speed) only accept drives attached to
  a verified organizer's track-day event, by an attendee who RSVP'd going,
  started within 3 km of the venue during the event window.
* Meet RSVPs never carry location. `show_me` defaults from the user's privacy
  setting, which defaults to off.
* `anon` (signed out) can't run any function or write any table, and every
  policy is for signed-in users. `20261016000800_security_hardening.sql`
  enforces this for Phase 1 functions, `20261017000500` for Phase 2's, and
  `006_security_surface.sql` keeps it true (see `SECURITY_REPORT.md`). New
  public functions must `revoke execute ... from public, anon`; a later
  migration can call `private.revoke_anon_execute('<its id>')` to do it and
  record what it removed.
* Owner-rights (`SECURITY DEFINER`) helpers that take a person as an
  argument answer only about the caller; the ones only triggers need aren't
  callable at all.

## Accounts and sign-in

* Sign in with Apple is the main path; email sign-in stays behind "Other
  sign-in options" for review and demo accounts. A new Apple account gets a
  placeholder username and goes through onboarding, which claims a real one
  (`claim_username`: reserved and staff-like names refused, case-insensitive
  uniqueness).
* Accounts are never merged because their emails match. A trigger on
  `auth.identities` refuses a second sign-in method unless the signed-in
  person asked for it in the last ten minutes (`begin_identity_link`). If
  the trigger can't be installed the migration warns loudly, and the release
  checklist has a step to confirm it.
* The app checks the Apple credential state at launch, on foreground and on
  Apple's revocation notice, and signs out if it was revoked. Account
  deletion revokes Apple's tokens when the person re-authenticates.

## Direct messages

One-to-one only (a canonical `user_a < user_b` pair, so one conversation per
two people and no groups). Every read goes through membership, membership
rows are private to their owner, messages are inserted as yourself only, and
a trigger enforces blocks, the "who can message you" setting, request limits
(three messages until accepted), rate limits and suspensions. A refused
`start_conversation` looks the same whatever the reason. Shared vehicles,
posts, meets and drive summaries are re-checked against the reader and never
carry a location. Read receipts are reciprocal and never sent for requests.
Messages are not end-to-end encrypted, and the conversation screen says so.
Old requests, cleared history and tombstones are purged by `dm-retention`.
The app listens on one realtime channel and refreshes from the server.

## Pull Up Pro

* The server is the only writer of `entitlements`. The app buys with
  StoreKit 2, tags the purchase with the user's id (`appAccountToken`), and
  sends the transaction to `verify-subscription`, which ignores the client's
  claims and asks Apple's App Store Server API for the subscription (status,
  expiry, grace period, revocation), then records it with
  `apply_entitlement`. A subscription unlocks one account; older data never
  overwrites newer; a working subscription is never replaced by a lapsed
  one.
* `app-store-notifications` receives Apple's V2 notifications as hints and
  re-fetches the subscription from Apple before changing anything.
* The app finishes a transaction only after the server has recorded it, so
  an interrupted purchase is retried at the next launch. Pro features read
  `my_entitlement()`; Pro looks fall back to the defaults while it's off.
* Prices on screen come from the App Store. Without products the paywall
  says Pro isn't on sale; demo mode uses a labelled store that takes no
  money.

## Notifications

`send-push` (database webhook, shared secret) takes only the notification
id and asks `push_content`, which applies the recipient's per-category
preferences and returns message text only when they turned previews on for
an accepted conversation. Tokens are registered with
`register_device_token`, which moves a token to the account that signed in
last on that phone; sign-out unregisters it; APNs `410` deletes it. Tapping
a push opens the conversation or the activity list.

## Parts finder

Stage A of `MARKETPLACE_FEASIBILITY.md`: the app builds an eBay search URL
from the vehicle's year, make, model and trim plus the part, shows exactly
what will be sent, and opens it in Safari. No listing, price or seller is
fetched or shown. eBay Partner Network parameters and the affiliate
disclosure are added only when a campaign id is configured.

## Demo mode

`DemoBackend` is an in-memory implementation of `BackendService` seeded with
fictional people, vehicles, meets and drives whose statistics are computed by
the real telemetry engine from synthetic tracks. It is used by SwiftUI
previews, UI tests and CI screenshots, and is reachable on a build without
server keys only through an explicit "Explore with demo data" button. While it
is active a "Demo data" strip is pinned to the top of every screen, and the
live dashboard says it is replaying a recorded track.

## CI

* `.github/workflows/ios.yml` (macos-26 runners, latest stable Xcode):
  * `PullUpKit tests`: Swift Testing suites for every package module on an
    iOS simulator.
  * `App build, UI tests, screenshots`: `xcodegen generate`, build, run the
    UI tests, upload the xcresult and screenshots, and publish the PNGs to
    the `ci/screenshots` branch (one folder per branch).
  * The app build also runs `PullUpStoreTests` (StoreKit purchases, Ask to
    Buy and expiry against `PullUpPro.storekit`, simulator only) in a step
    of its own on the iOS 26.2 simulator: on 26.4 and 26.5, command-line
    `xcodebuild test` never loads the StoreKit configuration (Apple
    FB22237318), so the tests would see no products.
* `.github/workflows/supabase.yml`: starts a real local Supabase stack, runs
  the pgTAP suite, lints, rolls every migration back and re-applies it,
  type-checks the edge functions and runs their Deno unit tests (Apple and
  APNs stubbed, no network).
  A second job starts the full local stack (auth, REST, realtime, storage,
  edge functions) and runs `supabase/tests/api/`: three throwaway accounts
  exercise every feature through the same HTTP and realtime APIs the app
  uses, including what each account must be refused.
* `.github/workflows/supabase-deploy.yml` (run by hand): applies the
  migrations and functions to the hosted `staging` or `production` project
  through a GitHub environment of the same name. It lists pending
  migrations first and refuses any that drop, truncate or retype data
  unless the file carries a named approval line
  (`supabase/scripts/check-pending-migrations.sh`). Staging runs then repeat
  the pgTAP and API tests against the project; production runs none that
  write. Setup: `SUPABASE_SETUP.md`.
