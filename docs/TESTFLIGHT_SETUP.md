# TestFlight setup

How to get Pull Up from GitHub onto your iPhone through TestFlight without
a Mac. Steps marked **You** need your Apple Developer or GitHub account;
the build, signing and upload run on a GitHub Actions macOS runner.

One build has been uploaded: Pull Up 0.1.0 (233), staging backend. Apple
accepted the upload but hasn't confirmed processing it, so it may not be on
TestFlight yet. Where each stage stands:

| Stage | Status |
| --- | --- |
| Unsigned Release archive | Passing: built by CI on pull requests that touch the app |
| Signed archive | Done 2026-10-24: 0.1.0 (233), staging, [run 40077637603](https://github.com/AaravJit/pull-up/actions/runs/40077637603) |
| Upload accepted by App Store Connect | Done 2026-10-24: "UPLOAD SUCCEEDED with no errors" in the same run |
| App Store Connect processing finished | Not confirmed yet |
| Installed on a device from TestFlight | Not done yet |

The Apple account steps below were done for that staging upload. The
production environment's values (step 4) are needed before a production
build.

## How it works

`.github/workflows/testflight.yml`, run by hand:

1. Writes `native/ios/Config/Secrets.xcconfig` from the GitHub environment
   you pick (`staging` or `production`), so the build talks to that
   Supabase project and says so in Settings ▸ About.
2. Archives the Release build. Signing is **cloud-managed**: Xcode asks
   Apple to sign using your App Store Connect API key, so there is no
   certificate or provisioning profile to export, store or renew.
3. Exports the `.ipa`, records a build provenance attestation for it,
   checks what the app declares and writes a provenance record
   (`native/ios/scripts/release-provenance.sh`), keeps the debug symbols as
   a run artifact for 90 days, and uploads the `.ipa` to App Store Connect.
   The `.ipa` itself isn't kept: the repository is public, so anyone signed
   in to GitHub could download a run's artifacts.

Which job does what:

| Job | Runs on | Signs | Exports `.ipa` | Uploads to Apple |
| --- | --- | --- | --- | --- |
| `unsigned`: Release archive (unsigned) | pull requests and `claude/**` pushes that touch the app | no (`CODE_SIGNING_ALLOWED=NO`) | no | no |
| `upload`: Build and upload | Run workflow by hand only (`workflow_dispatch`) | yes, Apple cloud signing with the API key | yes | yes, `xcrun altool` |

`ios.yml` builds a Debug app for the simulator and runs the tests; it never
archives, signs or uploads.

**Version.** `MARKETING_VERSION` in `native/ios/project.yml`, now `1.0`, the
version expected for the first App Store release of the "Pull Up – Drive &
Meet" app record. Settings ▸ About reads it (and the build) from the app
bundle, so it is never typed twice. It
changes only when someone edits it. The one earlier upload, 0.1.0 (233),
was a staging TestFlight build.

**Build number.** `native/ios/scripts/build-number.sh`: the workflow's run
number plus 100, and `<number>.<attempt>` when a run is re-run (Re-run jobs
keeps the run number, so a re-run after an upload went through would
otherwise repeat the number). Every run of `testflight.yml` takes a new run
number, so no two builds share one, and each upload is higher than the
last. The script refuses an upload numbered at or below 233, the last
upload, in case the run number is ever reset. The unsigned archive is
stamped the same way, so its number is checked on every pull request; it's
never uploaded. `project.yml`'s `CURRENT_PROJECT_VERSION` (1) is only for
local and simulator builds: an archive made on a Mac for upload must pass a
higher `CURRENT_PROJECT_VERSION` by hand.

On every pull request that touches the app, the same archive is built
unsigned, so a broken Release build shows up before you need it.

## 1. Apple Developer Program (**You**)

Enroll at developer.apple.com/programs if you haven't. It is a paid annual
membership, and nothing below works without it. Note your **Team ID**
(Membership details).

## 2. App ID and App Store Connect record (**You**)

1. Certificates, Identifiers & Profiles ▸ Identifiers ▸ **+** ▸ App IDs ▸
   App. Bundle ID: `app.pullup.ios` (or your own; then set
   `PULLUP_BUNDLE_ID`, step 4). Capabilities: **Sign in with Apple** and
   **Push Notifications**. Leave CarPlay off until Apple grants it
   (`CARPLAY.md`).
2. App Store Connect ▸ Apps ▸ **+** ▸ New App: platform iOS, name "Pull
   Up" (or the closest available), the bundle ID above, SKU `pullup-ios`.
   Done: the record is named "Pull Up – Drive & Meet". Its first App Store
   version is expected to be 1.0, which `MARKETING_VERSION` now matches;
   check the version shown under the app's iOS App section before
   submitting.
3. App Store Connect ▸ the app ▸ App Privacy: answer to match
   `native/ios/PullUp/PrivacyInfo.xcprivacy`, which declares 11 data types:
   precise location, email address, name, contacts, emails or text
   messages, photos or videos, other user content, user ID, device ID
   (push token), product interaction and other data types. All are linked
   to the person and collected for app functionality only; none is used
   for tracking. There is no purchase history and no search history. The
   required-reason APIs are UserDefaults (CA92.1) and file timestamps
   (C617.1). Xcode's privacy report (Organizer ▸ the archive ▸ Generate
   Privacy Report) has to be made on a Mac; CI can't produce it.

## 3. App Store Connect API key (**You**)

Users and Access ▸ Integrations ▸ App Store Connect API ▸ Team Keys ▸
**+**. Name it `GitHub TestFlight`, access **Admin**. Download the `.p8`
file (Apple offers it once), and note the **Key ID** and the **Issuer ID**
at the top of the page.

Why Admin: cloud-managed signing creates the distribution certificate for
you. Apple's [role table](https://developer.apple.com/support/roles/) gives
Account Holder and Admin full access to create cloud-managed certificates;
App Manager and Developer need a separate per-user permission, which Apple
doesn't document for team keys. So use a team key with the Admin role.
Individual keys can't use the provisioning endpoints
([Apple](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api)),
so they won't work here.

Treat the `.p8` like a password: it goes only into GitHub secrets (next
step). Delete the download afterwards.

## 4. GitHub environments (**You**)

In Settings ▸ Environments, add to both `staging` and `production` (the
same environments `SUPABASE_SETUP.md` creates):

| Kind | Name | Value |
| --- | --- | --- |
| Secret | `APP_STORE_CONNECT_KEY_ID` | Key ID |
| Secret | `APP_STORE_CONNECT_ISSUER_ID` | Issuer ID |
| Secret | `APP_STORE_CONNECT_PRIVATE_KEY` | the whole `.p8` file, including the BEGIN/END lines |
| Variable | `APPLE_TEAM_ID` | Team ID |
| Variable | `SUPABASE_ANON_KEY` | that project's anon (publishable) key; public by design |
| Variable (optional) | `PULLUP_BUNDLE_ID` | only if not `app.pullup.ios` |
| Variable (optional) | `PULLUP_PRIVACY_POLICY` | privacy policy URL without `https://`. Only to override `native/ios/Config/Base.xcconfig`, which sets the public GitHub page for every build; an empty variable changes nothing |
| Variable (optional) | `PULLUP_SUPPORT_URL` | support page URL without `https://`; same as above |
| Variable (optional) | `PULLUP_EPN_CAMPAIGN_ID` | eBay Partner Network campaign id |

`SUPABASE_PROJECT_REF` is already there from the Supabase setup. Keep
`production` limited to the `main` branch with you as required reviewer,
so a production build always waits for your approval. `staging` also
allows deployments from `main` only. The workflow also refuses a build
whose `SUPABASE_PROJECT_REF` isn't that environment's project (`staging` =
`hllfsfbuexuniosdewob`, `production` = `jxemvjxkspolyoknqkzr`), and a
production build that isn't from `main` or has no privacy policy URL.

The app is iPhone only for now (`TARGETED_DEVICE_FAMILY` 1 in
`native/ios/project.yml`), so App Store Connect needs iPhone screenshots
only. iPad can be added in a later version; it can't be removed once it
has shipped.

## 5. Build and upload

Actions ▸ **TestFlight** ▸ Run workflow, with "Use workflow from" on
`main` (the `staging` and `production` environments refuse runs from other
branches) ▸ backend `staging` ▸ optional "What to test" notes.

Since 2026-04-28 Apple only accepts uploads built with Xcode 26 or later
and the iOS 26 SDK
([Apple](https://developer.apple.com/news/upcoming-requirements/?id=04282026a)).
The workflow's `macos-26` runner with the latest-stable Xcode (26.6, with
the iOS 26.5 SDK, at the time of writing) meets that.

A green run means Apple **received** the build. It reaches TestFlight only
after App Store Connect finishes processing it (usually minutes, sometimes
longer) and it appears under TestFlight ▸ iOS Builds. Apple emails you if
processing finds a problem.

## 6. Install on your iPhone (**You**)

1. App Store Connect ▸ the app ▸ TestFlight ▸ Internal Testing ▸ **+** ▸
   create a group, add yourself, and tick **Enable automatic
   distribution**, so each processed build goes to the group.
2. Check the processed build is in the group; add it by hand if it isn't.
   Export compliance is answered by the build
   (`ITSAppUsesNonExemptEncryption` is `false`: Pull Up only uses standard
   HTTPS).
3. Install TestFlight on the iPhone 18 Pro Max. Open Apple's email invite
   on the iPhone and accept it in the TestFlight app, then install Pull Up.
   Then follow `DEVICE_TEST_PLAN.md`.

TestFlight builds expire after 90 days; run the workflow again for a fresh
one.

## Crash reports

Pull Up adds no crash-reporting SDK. Crashes from TestFlight and App Store
installs reach App Store Connect (TestFlight ▸ Crashes) and Xcode's
Organizer, symbolicated with the debug symbols the workflow uploads with
each build. Testers can also send screenshots and comments from the
TestFlight app. A third-party service (for example Sentry) would mean a new
data processor in the privacy answers, so it's left for you to decide.

## Checking a build's provenance

Each `.ipa` the workflow uploads has a GitHub attestation tying its SHA-256
to the commit and workflow run that built it (the repository's Attestations
page lists them). It records which commit and run produced the build Apple
received. The `.ipa` isn't kept as an artifact, so checking a file against
it (`gh attestation verify PullUp.ipa -R AaravJit/pull-up`) needs a copy
you saved yourself.

Each run also writes a provenance record, in the job summary and as the
artifact `PullUp-<version>-<build>-provenance` (`-unsigned-provenance` for
the pull request archive): commit, ref, run id and attempt, version, build,
bundle ID, device family, background modes, backend environment, Xcode,
and for an upload the `.ipa`'s SHA-256, the signed entitlement names, the
attestation link, the upload step's outcome and altool's delivery UUID.
Names and numbers only: no key, key ID, certificate, profile or team ID.
In the upload job the same step unzips the exported `.ipa` and checks the
signed app inside it, before the upload, failing the job on any of:

- `CFBundleShortVersionString` isn't `MARKETING_VERSION` (1.0) or
  `CFBundleVersion` isn't the build picked;
- `CFBundleIdentifier` isn't `app.pullup.ios`, or `MinimumOSVersion` isn't
  18.0;
- `UIDeviceFamily` isn't `[1]` (iPhone only), or `UIBackgroundModes` is
  anything but `location`;
- `NSUserTrackingUsageDescription` is present, or the scene manifest
  mentions CarPlay;
- `PrivacyInfo.xcprivacy` is missing or invalid;
- any of the four public page links (privacy, support, terms, community)
  is empty, unexpanded or written with a scheme;
- the signed entitlements (`codesign -d --entitlements`) aren't exactly
  what signing adds (`application-identifier`, team identifier,
  `keychain-access-groups`, `get-task-allow` false, `beta-reports-active`)
  plus Sign in with Apple and `aps-environment` `production`. Any other
  key, a CarPlay entitlement included, fails. Add a key to the list in
  `release-provenance.sh` only together with the feature that needs it.

The unsigned pull request job runs the same checks, except the
entitlement ones, on its unsigned archive.

Apple's processing isn't checked by the workflow. A record with upload
step `success` means only that altool delivered the file.

For the one upload so far, made before this record existed, the facts from
[run 40077637603](https://github.com/AaravJit/pull-up/actions/runs/40077637603)'s
log: commit `5e494b993e8db7927ba307bf65a6a889852af474` on `main`, run
number 133 attempt 1, `staging` environment, Xcode 26.6 (17F113), Pull Up
0.1.0 (233), `.ipa` SHA-256
`65abf5c37fb554807ed7d6d00f3b10fadd488bff6f684a3c38052edbcc93f294`
([attestation 59373956](https://github.com/AaravJit/pull-up/attestations/59373956)),
dSYMs artifact `PullUp-0.1.0-233-dSYMs`, delivery UUID
`e7fd6f3e-0604-4092-b073-2d4a02c11e5c`.

## If a run fails

| Message | Cause | Fix |
| --- | --- | --- |
| "a resolved file is required" or "out-of-date resolved file" | `native/ios/Package.resolved` is missing or no longer matches the package requirements | update the pins as `native/ios/scripts/pin-packages.sh` explains and commit both `Package.resolved` files |
| "The staging environment is missing: …" | a secret or variable from step 4 isn't set | add it |
| "Branch … is not allowed to deploy to staging" | the run was started from a branch other than `main` | run it from `main` (step 5) |
| "No profiles for 'app.pullup.ios' were found" or a certificate error | the API key isn't Admin, or the App ID is missing | step 3 role, step 2.1 |
| "Your team has no devices from which to generate a provisioning profile" (possible on the first signed run; not seen yet) | the team has no registered device | register the iPhone (its UDID) in Certificates, Identifiers & Profiles ▸ Devices, then run again |
| "No suitable application records were found" | no App Store Connect app for that bundle ID | step 2.2 |
| "The bundle version must be higher" | a build with that number was uploaded by hand | raise `OFFSET` (and `LAST_UPLOADED_BUILD`) in `native/ios/scripts/build-number.sh` |
| "Build … is not above the last uploaded build 233" | the workflow's run number was reset (file renamed or recreated) | raise `OFFSET` in `native/ios/scripts/build-number.sh` |
| A provenance check fails ("UIDeviceFamily is …", "a CarPlay scene is declared …") | the built app declares something it shouldn't | fix `Info.plist`, `project.yml` or the entitlements; nothing was uploaded |
| Upload passes but no build appears | Apple is still processing, or rejected it by email | wait, then check the email |
