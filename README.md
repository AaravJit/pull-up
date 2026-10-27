# Pull Up

**Pull Up is a native iPhone app for drivers and riders.** Its release app is written in Swift and SwiftUI under `native/ios/`. The top-level Expo/React Native code is an **older prototype**, not the iOS build intended for App Store submission.

Product order: **driving first, community second, parts discovery third.** The native app has five tabs: Drive, Map, Feed, Meets, and Garage, with supporting flows for profiles, settings, messages, leaderboards, onboarding, and account deletion. Speed and acceleration are not competitive leaderboard metrics. GPS measurements are estimates, not certified instrumentation.

## Repository map

| Path | Purpose |
| --- | --- |
| `native/ios/` | Native SwiftUI app, XcodeGen project specification, app shell and UI tests |
| `native/ios/Packages/PullUpKit/` | Swift packages for domain, telemetry, data, Core Location, design system and features |
| `supabase/` | Database migrations, RLS tests, Edge Functions, rollback scripts and API tests |
| `.github/workflows/ios.yml` | Package tests, iOS simulator tests and CI screenshots |
| `.github/workflows/testflight.yml` | Release archive / TestFlight path; distinguish unsigned builds from signed uploads |
| `.github/workflows/supabase-deploy.yml` | Manual, environment-scoped backend dry run or deployment |
| `docs/PROGRESS.md` and `docs/RELEASE_CHECKLIST.md` | Status and unresolved owner/device work |
| `src/` | Legacy Expo prototype; **not** the native release app |

## Open the native project

On a Mac with a compatible Xcode toolchain and XcodeGen:

```sh
cd native/ios
xcodegen generate
open PullUp.xcodeproj
```

`native/ios/project.yml` is the source of truth for the generated Xcode project. `Config/Base.xcconfig` holds safe defaults; copy `Config/Secrets.example.xcconfig` to the gitignored `Config/Secrets.xcconfig` to configure a personal signed build or a real Supabase backend. **Never commit private API keys, service-role keys, Apple signing material or user data.** The app labels demo data explicitly when no backend is configured.

For reproducible tests, see the iOS and Backend GitHub Actions workflows and `docs/DEVICE_TEST_PLAN.md`. Passing simulator tests is not a substitute for testing Apple sign-in, location recording with the phone locked, notifications, and other device-dependent behavior on a physical iPhone.

## Release status

**Pre-release; production readiness has not been demonstrated.** As of the October 26, 2026 audit of `main` at `2addf202`, the checked-in app marketing version is `0.1.0`. A signed `0.1.0 (233)` staging-backed build was uploaded on October 24, but successful App Store Connect processing and installation were not confirmed in the repository. Version `1.0` changes and other release-critical fixes are under review in separate draft PRs; do not treat those branches as shipped.

Start with `docs/RELEASE_INTEGRATION_GATES_20261026.md`, `docs/RELEASE_CHECKLIST.md`, and `docs/PROGRESS.md` before making release claims. The public launch requires owner approval and evidence from the actual signed app, hosted backend, and physical-device testing.

The app does **not** advertise CarPlay, verified eBay fitment, live friend locations, or paid Pull Up Pro subscriptions as supported launch features.

## Legacy Expo prototype

The original Expo prototype remains at the root; `npm install` / `npm start` work on that **prototype**, not on the shipping SwiftUI app. Do not send App Store release contributors to it by default.
