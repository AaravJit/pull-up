# Progress

Native iOS rebuild of Pull Up on branch `claude/native-ios-85igsc`. The Expo
app at the repository root is unchanged.

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
  once `Secrets.xcconfig` is filled in (see `RELEASE_CHECKLIST.md`). Not yet
  run against a hosted project.
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
| Account | Email sign-in/up, email confirmation link | Needs backend | `pullup://auth-callback` handled |
| Account | Sign in with Apple | Needs Apple | Services ID + key in Supabase (checklist §3) |
| Account | Delete account (server side) | Needs backend | `delete-account` edge function, type-checked in CI |
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

* Not yet run against a hosted Supabase project; all server behaviour is
  verified on the local Supabase stack in CI.
* No snapshot tests; visual review is done from CI screenshots.
* App icon is a generated placeholder gauge.
