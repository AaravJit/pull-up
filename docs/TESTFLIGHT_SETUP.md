# TestFlight setup

How to get Pull Up from GitHub onto your iPhone through TestFlight without
a Mac. Steps marked **You** need your Apple Developer or GitHub account;
the build, signing and upload run on a GitHub Actions macOS runner.

No TestFlight build exists yet. The workflow has only built the Release
archive unsigned; it hasn't signed or uploaded anything, because the Apple
account steps below haven't been done.

## How it works

`.github/workflows/testflight.yml`, run by hand:

1. Writes `native/ios/Config/Secrets.xcconfig` from the GitHub environment
   you pick (`staging` or `production`), so the build talks to that
   Supabase project and says so in Settings ▸ About.
2. Archives the Release build. Signing is **cloud-managed**: Xcode asks
   Apple to sign using your App Store Connect API key, so there is no
   certificate or provisioning profile to export, store or renew.
3. Exports the `.ipa`, records a build provenance attestation for it, keeps
   the debug symbols as a run artifact for 90 days, and uploads the `.ipa`
   to App Store Connect. The `.ipa` itself isn't kept: the repository is
   public, so anyone signed in to GitHub could download a run's artifacts.

The build number is the workflow's run number plus 100, so every upload is
higher than the last. The version (`MARKETING_VERSION` in
`native/ios/project.yml`, now `0.1.0`) changes only when someone edits it.

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
3. App Store Connect ▸ the app ▸ App Privacy: answer to match
   `native/ios/PullUp/PrivacyInfo.xcprivacy`: precise location, email,
   name, user ID, device ID (push token), photos, messages, other user
   content and purchase history, all linked to the person, all for app
   functionality, none for tracking.

## 3. App Store Connect API key (**You**)

Users and Access ▸ Integrations ▸ App Store Connect API ▸ Team Keys ▸
**+**. Name it `GitHub TestFlight`, access **Admin**. Cloud-managed
signing creates the distribution certificate for you, and Apple only lets
Admin keys do that. Download the `.p8` file (Apple offers it once), and
note the **Key ID** and the **Issuer ID** at the top of the page.

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
| Variable (optional) | `PULLUP_PRIVACY_POLICY` | privacy policy URL without `https://`; required before Pro goes to review |
| Variable (optional) | `PULLUP_EPN_CAMPAIGN_ID` | eBay Partner Network campaign id |

`SUPABASE_PROJECT_REF` is already there from the Supabase setup. Keep
`production` limited to the `main` branch with you as required reviewer,
so a production build always waits for your approval.

## 5. Build and upload

Actions ▸ **TestFlight** ▸ Run workflow ▸ backend `staging` ▸ optional
"What to test" notes. (GitHub lists a hand-run workflow only once it is on
`main`.)

A green run means Apple **received** the build. It reaches TestFlight only
after App Store Connect finishes processing it (usually minutes, sometimes
longer) and it appears under TestFlight ▸ iOS Builds. Apple emails you if
processing finds a problem.

## 6. Install on your iPhone (**You**)

1. App Store Connect ▸ the app ▸ TestFlight ▸ Internal Testing ▸ **+** ▸
   create a group and add yourself.
2. Add the processed build to the group. Export compliance is answered by
   the build (`ITSAppUsesNonExemptEncryption` is `false`: Pull Up only uses
   standard HTTPS).
3. Install TestFlight on the iPhone 18 Pro Max, sign in with the same
   Apple ID, and install Pull Up. Then follow `DEVICE_TEST_PLAN.md`.

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

## If a run fails

| Message | Cause | Fix |
| --- | --- | --- |
| "The staging environment is missing: …" | a secret or variable from step 4 isn't set | add it |
| "No profiles for 'app.pullup.ios' were found" or a certificate error | the API key isn't Admin, or the App ID is missing | step 3 role, step 2.1 |
| "No suitable application records were found" | no App Store Connect app for that bundle ID | step 2.2 |
| "The bundle version must be higher" | a build with that number was uploaded by hand | raise the offset in the workflow |
| Upload passes but no build appears | Apple is still processing, or rejected it by email | wait, then check the email |
