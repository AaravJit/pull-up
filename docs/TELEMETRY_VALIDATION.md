# Telemetry validation

How well Pull Up's drive recording holds up, and how that was checked.

**Everything on this page comes from synthetic drives replayed in CI.** No
real drive has been recorded with this build yet. The numbers say the
algorithms behave on the tracks below; they don't say what a real iPhone's
GPS will produce. Real-drive checks are in `DEVICE_TEST_PLAN.md` (section 3)
and their results go in `PROGRESS.md`.

## What runs in CI

`Tests/PullUpTelemetryTests/ScenarioTests.swift` (suite "Replay scenarios")
builds nine drives second by second, keeps the true distance alongside what
a phone would report, and feeds the reported fixes through the same
`TelemetryEngine` the app uses. Each test attaches one `SCENARIO` line to the
test results; the iOS workflow copies those lines into the run's job summary under "Telemetry
replay report".

How the synthetic GPS behaves:

* Position error is a slow random walk (AR(1), 3 m spread per axis,
  correlation 0.95 from one second to the next), because real GPS error
  drifts rather than jumping independently on every fix.
* Reported horizontal accuracy is 4 to 10 m, Doppler speed error 0.2 m/s.
* One fix per second while there is signal, none in tunnels.
* At lights iOS pauses location updates after a few seconds still (the
  `stationary` flag on `CLLocationUpdate`); the scenarios emit the same
  pause and resume events.
* The noise is seeded, so every run replays exactly the same tracks.

## Results

Run on commit `df902e4` (iOS workflow, PullUpKit tests job, 18 Oct 2026).

| Scenario | True distance | Measured | Error | Bridged | Longest gap | Top speed m/s (measured / true) | Fixes accepted / rejected |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Urban blocks with lights | 3,900 m | 3,888 m | −0.31 % | 0 m | 0 s | 13.4 / 13.0 | 380 / 0 |
| Highway cruise | 56,298 m | 56,296 m | −0.00 % | 0 m | 0 s | 33.5 / 33.0 | 1,825 / 0 |
| Stop-and-go traffic | 2,500 m | 2,462 m | −1.51 % | 0 m | 0 s | 5.3 / 5.0 | 920 / 0 |
| Tunnel | 4,730 m | 4,724 m | −0.13 % | 1,998 m | 91 s | 22.3 / 22.0 | 130 / 0 |
| Multipath jumps | 1,515 m | 1,527 m | +0.79 % | 0 m | 0 s | 15.5 / 15.0 | 152 / 2 |
| Bad first fix (1 relock) | 910 m | 913 m | +0.30 % | 0 m | 0 s | 14.2 / 14.0 | 80 / 0 |
| Parking lot, low speed | 246 m | 245 m | −0.40 % | 0 m | 0 s | 2.3 / 2.0 | 136 / 0 |
| Two hours, mixed | 140,988 m | 140,894 m | −0.07 % | 3,713 m | 31 s | 30.5 / 30.0 | 6,456 / 0 |

The stationary-pause scenario checks behaviour (speed 0, no gap counted) rather than distance, so it has no row.

Measured top speeds sit 0.2 to 0.5 m/s above the true ones. The synthetic Doppler error is added to every reading, and the highest of many three-reading medians tends to land on the high side of that noise. Stop-and-go has the largest error, 1.5 % short; it is inside that scenario's bound but is the one to watch on real drives.

"Error" is measured distance against true distance. "Bridged" is distance
added across a signal gap by joining the fixes either side; the summary
always discloses it.

## What the engine does with bad data

| Problem | What happens | Scenario |
| --- | --- | --- |
| Stopped at lights | iOS pauses updates; the engine treats the pause as a known zero, not lost signal. Speed shows 0, the gap isn't counted | urban, stationary pause |
| GPS jitter while parked or crawling | At short intervals, distance follows the Doppler speed when it agrees with the position change, so wander doesn't add up | low speed, stop-and-go |
| Multipath jump off a building | A fix further away than the Doppler speed allows (plus each reading's speed uncertainty, 2 m/s and both accuracy radii) is rejected | multipath, unit tests |
| Wrong cached first fix | After three consistent fixes that all disagree with the first, the engine relocks on them and drops it | bad first fix |
| Tunnel or garage | "GPS signal lost" while inside, no speed shown. The gap is bridged in a straight line and disclosed with its length | tunnel |
| Implausible speed or acceleration | Above 120 m/s, or above 16 m/s² between Doppler readings, a fix is rejected | unit tests |
| Accuracy worse than 35 m | Rejected (cell and Wi-Fi fixes never count) | unit tests |
| App relaunched by recovery, or upload retried | The drive is rebuilt from stored fixes and stationary pauses; the result matches what was shown live | two hours |

## Limits

* **Force-quit.** If the person swipes Pull Up away in the app switcher, iOS
  stops delivering location and the app can't prevent it. On the next launch
  within 15 minutes the drive resumes with a notice and the closed time shows
  as a gap; after that, the drive is finished at its last fix. iOS also
  stops the app in low-memory situations; the same recovery applies.
* **Background.** Recording continues with the screen locked or another app
  open because the app holds a `CLBackgroundActivitySession` (When In Use
  permission, blue location indicator) only while a drive is recording. That has only been checked in the
  simulator; D3.1 and D3.11 check it on a phone.
* **Battery.** No battery numbers exist. The simulator can't measure them;
  D3.17 records the first real ones. When Low Power Mode is on, the
  dashboard says iOS may deliver fewer fixes and numbers may be less
  precise; how much less hasn't been measured.
* **0 to 60 mph.** Phone GPS reports speed about once a second, so a 5 s run
  has around six readings. Times are interpolated and labelled an estimate
  unless every gap was 1.1 s or less with speed accuracy within 1 m/s; even
  then the app says "GPS consistent", never "measured". Runs under 1.9 s are
  discarded as artefacts. Pull Up never asks anyone to accelerate hard, and
  leaderboards don't rank street speed.
* **Tunnels with turns.** Bridging is a straight line, so a curving tunnel
  undercounts slightly. The summary shows how much was bridged.
* **Elevation.** Distance is horizontal only. On steep roads it reads a
  little short (about 0.5 % at a 10 % grade).
* **Speedometers.** Car speedometers usually read a few percent high, so a
  GPS top speed slightly below the speedometer is expected.

## Re-running

Push to a branch with an open pull request, or run the iOS workflow by hand
(Actions ▸ iOS ▸ Run workflow). The "Telemetry replay report" step lists
the `SCENARIO` lines. To change a scenario, edit `ScenarioTests.swift`; the
bounds in each `#expect` are the pass criteria.
