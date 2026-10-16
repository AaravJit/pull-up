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
  Packages/PullUpKit/      Everything else, as a local Swift package
  scripts/                 CI helpers (simulator picker, readable xcodebuild output)
supabase/
  migrations/              Seven forward migrations
  rollback/                Matching down migrations, destructive steps guarded
  tests/                   pgTAP suite: RLS, privacy, anti-spoofing, redaction
  functions/               Edge functions: delete-account, send-push (APNs)
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
* `anon` has no privileges on any table or function.

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
* `.github/workflows/supabase.yml`: starts a real local Supabase stack, runs
  the pgTAP suite, lints, rolls every migration back and re-applies it, and
  type-checks the edge functions.
