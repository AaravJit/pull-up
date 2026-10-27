# Release checklist

Everything below needs a person with the Apple Developer account, the
Supabase project, or a physical iPhone. Nothing here can be done from CI
alone. Items are in the order they unblock each other.

## 1. Supabase project

The step-by-step version, with the GitHub deploy workflow that automates
most of this, is `SUPABASE_SETUP.md`.

Staging is done for the first, second and fourth items and partly for
the third (`STAGING_DEPLOYMENT.md`). On 2026-10-23 the owner set the
sign-up hook, the redirect URL and the Apple provider in the staging
dashboard; none of these has been verified end to end. Production is
still to do.

- [ ] Create a Supabase project (or pick the existing one) and note the
      project ref and anon key (Project Settings ▸ API). Staging
      (`pull-up-staging`) exists; production hasn't been created.
- [ ] Apply the schema: the `Supabase deploy` workflow does this
      (`SUPABASE_SETUP.md` §4), or by hand with the Supabase CLI:
      `supabase link --project-ref <ref>` then `supabase db push`.
      All 24 migrations are additive. Each has a matching file in
      `supabase/rollback/` (CI rolls every one back and re-applies it), and
      rollbacks that would drop data refuse to run unless
      `pullup.allow_destructive_rollback` is set for the session. Staging
      has all 24.
- [ ] Run `supabase test db` against a staging project (the same pgTAP
      suite CI runs). On staging: files 001–014, 262 of 262, on
      2026-10-20; `015_follow_requests.sql` (#21) hasn't run there yet.
      The two-account API suite hasn't been rerun there since 2026-10-18.
- [ ] Deploy edge functions: `supabase functions deploy delete-account send-push
      dm-retention verify-subscription app-store-notifications`. All five
      are on staging.
- [ ] Generate a random push webhook secret (`openssl rand -hex 32`) and
      add `PUSH_WEBHOOK_SECRET` as a secret in the GitHub environment
      (`SUPABASE_SETUP.md` §3); the next Supabase deploy run with apply
      ticked copies it to the project. Don't set it with
      `supabase secrets set`: a deploy removes any function secret that
      isn't in the environment.
- [ ] Database ▸ Webhooks: enable webhooks (installs the `pg_net`
      extension), then on INSERT into `public.notifications`, call the
      `send-push` function with the HTTP headers
      `x-pullup-webhook-secret: <same value>` and
      `Authorization: Bearer <anon key>` (the function keeps Supabase's JWT
      check). Requests without the secret are
      rejected. Without the webhook, notifications still appear in the app's
      bell; they just aren't pushed.
- [ ] Auth ▸ Hooks: enable **Before User Created** with
      `public.hook_before_user_created` (`SUPABASE_SETUP.md` §5). Staging:
      done 2026-10-23 (owner, dashboard), not verified end to end.
- [ ] Auth ▸ Providers: enable Apple (see 3). Staging: done 2026-10-23
      (owner, dashboard), not verified end to end. Keep Email enabled for the
      App Review demo account; the app offers email sign-in only, behind
      "Other ways to sign in". Leave "Allow new users to sign up" on: it
      covers every provider, Apple included.
- [ ] Confirm the account-linking guard is installed (it stops Supabase
      from merging an Apple sign-in into an email account with the same
      address): `select tgname from pg_trigger where tgname =
      'pullup_identity_link_guard';` must return one row. If `db push`
      printed "pullup_identity_link_guard was not installed", ask Supabase
      support how to add a trigger on `auth.identities` on your plan before
      launch, and keep "Allow manual linking" off meanwhile.
- [ ] Auth ▸ URL configuration: add `pullup://auth-callback` as a redirect URL
      for email confirmation links. Staging: done 2026-10-23 (owner,
      dashboard), not verified end to end.

## 2. App configuration (no secrets in git)

- [ ] Copy `native/ios/Config/Secrets.example.xcconfig` to
      `native/ios/Config/Secrets.xcconfig` (gitignored) and fill in
      `PULLUP_TEAM_ID`, `PULLUP_SUPABASE_HOST`, `PULLUP_SUPABASE_ANON_KEY` and,
      if `app.pullup.ios` is taken, `PULLUP_BUNDLE_ID`.
      The anon key is public by design; authorization is enforced by RLS.
      The service-role key must never go in the app.
- [x] For CI-signed builds, the TestFlight workflow (`testflight.yml`)
      writes `Secrets.xcconfig` before `xcodegen generate`, from the GitHub
      environment's variables (`TESTFLIGHT_SETUP.md`).
- [ ] A build without these values shows a "Server not configured" screen
      with an explicit demo-data option. It never shows fake data silently.

## 3. Apple Developer account

- [ ] Register the App ID with capabilities: Sign in with Apple, Push
      Notifications. (CarPlay: see 5.)
- [ ] Sign in with Apple: in Supabase ▸ Auth ▸ Providers ▸ Apple, enable it
      and put the app's bundle ID `app.pullup.ios` (or `PULLUP_BUNDLE_ID`)
      in Client IDs. The app signs in natively (`signInWithIdToken`), which
      accepts only token audiences listed there. A Services ID and secret
      key are only needed for web sign-in. The deploy workflow's "Report
      the sign-in settings" step prints whether the bundle
      ID is listed. The app sends a SHA-256 nonce; Supabase verifies it.
- [ ] APNs: create an APNs auth key (.p8). Add `APNS_KEY_ID`,
      `APNS_TEAM_ID`, `APNS_TOPIC` (the bundle ID) and `APNS_PRIVATE_KEY`
      (the whole `.p8` file) as secrets in the GitHub environment
      (`SUPABASE_SETUP.md` §3); the next Supabase deploy run with apply
      ticked copies them to the project. Don't set them with
      `supabase secrets set`: a deploy removes any function secret that
      isn't in the environment. The app reports whether its token is
      sandbox or production, and the function routes accordingly.
- [ ] `aps-environment` in `PullUp.entitlements` is `development`. Archive
      builds for TestFlight/App Store get `production` from the distribution
      profile automatically.

## 4. Signing, TestFlight, App Store

- [x] Create the app record in App Store Connect with the bundle ID:
      "Pull Up – Drive & Meet".
- [ ] App Store version 1.0. `MARKETING_VERSION` is `1.0` in
      `native/ios/project.yml`; confirm App Store Connect shows 1.0 for the
      version being submitted. Build numbers come from
      `native/ios/scripts/build-number.sh` (above 233, the one upload so
      far).
- [ ] App Store Connect ▸ the app ▸ Pricing and Availability: turn off
      **Make this app available on Mac** (Apple silicon) and **Apple Vision
      Pro**. The build already opts out
      (`SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD` and
      `SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD` are `NO` in `project.yml`),
      but the store setting is separate.
- [ ] The submitted build's provenance record (job summary and
      `PullUp-1.0-<build>-provenance` artifact of its TestFlight run) shows
      the expected commit on `main`, the `production` environment, and no
      problems.
- [ ] Archive: either on a Mac (`xcodegen generate`, open `PullUp.xcodeproj`,
      Product ▸ Archive), or run Actions ▸ TestFlight from `main`, which
      archives with an App Store Connect API key and
      `-allowProvisioningUpdates` (`TESTFLIGHT_SETUP.md`). No signing
      material is in the repo.

TestFlight, stage by stage:

- [x] Unsigned Release archive: built by CI on pull requests that touch
      the app, passing.
- [x] Signed archive: 0.1.0 (233), staging backend, 2026-10-24,
      [run 40077637603](https://github.com/AaravJit/pull-up/actions/runs/40077637603).
- [x] Upload accepted by App Store Connect: "UPLOAD SUCCEEDED with no
      errors" in the same run.
- [ ] App Store Connect processing finished. Not confirmed yet.
- [ ] Installed on a device from TestFlight. Not done yet.

App Store:

- [ ] App Privacy answers, matching `PrivacyInfo.xcprivacy`, which declares
      11 data types: precise location, email address, name, contacts,
      emails or text messages, photos or videos, other user content, user
      ID, device ID (push token), product interaction and other data types.
      All are linked to the user and collected for app functionality only;
      none is used for tracking. No purchase history and no search history.
      Required-reason APIs: UserDefaults (CA92.1) and file timestamps
      (C617.1).
- [ ] Xcode privacy report: on a Mac, open the archive in Xcode ▸ Organizer
      and choose Generate Privacy Report, then check it against the App
      Privacy answers above. CI can't produce this report (`xcodebuild` has
      no command for it); the TestFlight workflow only checks that the
      signed app contains a valid `PrivacyInfo.xcprivacy`.
- [ ] Review notes: explain background location (only while a drive is
      recording, started by the user; When In Use only, never Always),
      account deletion (Settings ▸ Account ▸ Delete account, server side), and
      that leaderboards never rank street speed.
- [ ] Provide a demo account with seeded data for App Review.
- [ ] Replace the generated gauge app icon if you want a designed one.

## 4a. Phase 2 services

Messages

- [ ] Check that realtime is on for messages: Database ▸ Publications ▸
      `supabase_realtime` lists `messages` and `message_reactions`. (The
      migration adds them and prints a notice if the publication is missing.)
- [ ] Generate `CRON_SECRET` (`openssl rand -hex 32`) and add it as a
      secret in the GitHub environment (`SUPABASE_SETUP.md` §3); the next
      Supabase deploy run with apply ticked copies it to the project. Don't
      set it with `supabase secrets set`: a deploy removes any function
      secret that isn't in the environment. Then schedule
      `dm-retention` daily: enable Integrations ▸ Cron (installs `pg_cron`)
      and Database ▸ Webhooks (installs `pg_net`, which makes the HTTP
      call), store the secret in Vault rather than pasting it into the
      job, and have the job send headers `x-pullup-cron-secret: <value>`
      (read from Vault) and `Authorization: Bearer <anon key>`. The SQL is
      in `SUPABASE_SETUP.md` §5.
- [ ] Decide who reviews reports (`public.reports`) and how quickly.
      Suspensions are set by the service role on
      `profiles.messaging_suspended_until`. Nothing alerts anyone to a new
      report yet: `report_user` only sends `pg_notify('pullup_reports', …)`,
      which nothing listens to.

Sign in with Apple token revocation (account deletion)

- [ ] Create a Sign in with Apple key and add `APPLE_TEAM_ID`,
      `APPLE_CLIENT_ID` (the bundle ID), `APPLE_KEY_ID` and
      `APPLE_PRIVATE_KEY` (the whole `.p8` file) as secrets in the GitHub
      environment (`SUPABASE_SETUP.md` §3); the next Supabase deploy run
      with apply ticked copies them to the project. Don't set them with
      `supabase secrets set`: a deploy removes any function secret that
      isn't in the environment. Without them accounts are still deleted,
      and the app tells the person how to remove Pull Up from their Apple
      Account.

Pull Up Pro (nothing here is done; prices are placeholders)

- [ ] Accept the Paid Apps agreement and add banking and tax details in
      App Store Connect.
- [ ] Create one subscription group with `app.pullup.pro.monthly` and
      `app.pullup.pro.yearly`. The placeholder prices in the local StoreKit
      file are $3.99 and $29.99; choose real prices yourself. Add the review
      screenshot and description each product needs.
- [ ] Create an In-App Purchase key (Users and Access ▸ Integrations ▸ In-App
      Purchase) and add `APPSTORE_ISSUER_ID`, `APPSTORE_KEY_ID`,
      `APPSTORE_BUNDLE_ID` (the bundle ID) and `APPSTORE_PRIVATE_KEY` (the
      whole `.p8` file) as secrets in the GitHub environment
      (`SUPABASE_SETUP.md` §3); the next Supabase deploy run with apply
      ticked copies them to the project. Don't set them with
      `supabase secrets set`: a deploy removes any function secret that
      isn't in the environment.
- [ ] App Store Connect ▸ App Information ▸ App Store Server Notifications:
      set both the Production and Sandbox URL to
      `https://<project-ref>.supabase.co/functions/v1/app-store-notifications`,
      Version 2. Send a test notification and check the function log shows it.
- [x] Publish a privacy policy and set `PULLUP_PRIVACY_POLICY` (without
      `https://`). The public pages are in `docs/public/` (#30), and
      `native/ios/Config/Base.xcconfig` sets `PULLUP_PRIVACY_POLICY`,
      `PULLUP_SUPPORT_URL`, `PULLUP_TERMS_URL` and `PULLUP_COMMUNITY_URL` to
      their GitHub pages for every build (Settings ▸ About lists all four;
      `LegalLinks` in PullUpFeatures reads them). A GitHub environment
      variable or `Secrets.xcconfig` overrides one only when set.
      App Store Connect still needs the complete https URLs typed in
      (`PUBLIC_PAGES_RELEASE.md`). The paywall links Apple's standard
      Terms of Use for the subscription.
- [ ] Sandbox test on a device with a sandbox Apple Account: buy, renew,
      cancel, refund (via the sandbox settings), Ask to Buy, and restore on a
      second phone. Only then submit the products with the app version.
- [x] Add the per-user rate limit on `verify-subscription`
      (`SECURITY_REPORT.md` R-4). Done in migration `20261018000200`
      (PR #7).

Notifications

- [ ] After the APNs key (3) and webhook (1) are set, test on a device:
      message push shows the sender but not the text; turning previews on
      shows it; a request never shows text; turning a category off stops it;
      tapping opens the conversation; signing in as someone else on the same
      phone stops the first account's pushes.
- [ ] `send-push` answers `{ sent, failed }`. `sent` only means APNs
      accepted the push; it counts as delivered once it shows up on the
      phone. Refusals are in the function's logs as `APNs <environment>
      refused a push: <status> <reason>` (never the token or the text):
      `InvalidProviderToken` means the key, team ID or topic is wrong;
      `BadDeviceToken` means a sandbox token went to production or the
      reverse, and that token is removed. Tokens for deleted apps (410) are
      removed too.

Parts finder

- [ ] Optional: join the eBay Partner Network and set
      `PULLUP_EPN_CAMPAIGN_ID`. The app then adds the affiliate parameters and
      shows the disclosure. Listings inside the app need eBay Buy API
      approval first (`MARKETPLACE_FEASIBILITY.md`).

Security

- [ ] Run `supabase test db` against staging, including
      `006_security_surface.sql`. Files 001–014 passed there, 262 of 262,
      on 2026-10-20 (`STAGING_DEPLOYMENT.md`); `015_follow_requests.sql`
      (#21) hasn't run on staging yet.
- [ ] Work through "Still to do" in `SECURITY_REPORT.md`.

## 5. CarPlay

See `docs/CARPLAY.md`. Request the Driving Task entitlement, enable it on
the App ID, set `PULLUP_ENTITLEMENTS = PullUp/PullUp-CarPlay.entitlements`
in `Secrets.xcconfig`. The TestFlight workflow doesn't write that setting,
so its builds use `PullUp/PullUp.entitlements` (no CarPlay) until a pull
request changes the workflow or `Base.xcconfig`. That pull request also
declares the CarPlay scene in `Info.plist` again (`CARPLAY.md` step 3);
the shipping build declares none.

## 6. Physical-device testing (cannot be done in a simulator)

- [ ] First-run permission flow: tap Start Drive, pick a vehicle, confirm;
      the location prompt appears only then. Deny once and check the
      "Open Settings" path.
- [ ] Precise Location off: the temporary full-accuracy prompt appears and
      declining shows the reduced-accuracy notice.
- [ ] Record a real 10+ minute drive with the phone locked and the app in the
      background. Confirm the blue location pill, that recording continues,
      and that distance/top speed look right against the car's trip meter.
- [ ] Stop at lights: the dashboard shows 0 (stationary), not "signal lost".
- [ ] Tunnel or parking garage: signal-lost notice, gap disclosed on summary.
- [ ] Airplane mode at stop: drive saved offline, uploads on next launch.
- [ ] Force-quit mid-drive: next launch recovers the interrupted drive.
- [ ] Battery use over a one-hour drive.
- [ ] Sign in with Apple (the simulator can't complete it reliably).
- [ ] Push notifications end to end (follow from a second account), and the
      checks under 4a ▸ Notifications.
- [ ] Photo upload from the library: confirm EXIF GPS is stripped (download
      the stored file and inspect it).
- [ ] Video post playback over cellular.
- [ ] CarPlay on a head unit once the entitlement is granted.
- [ ] Share a route and check that it starts and ends away from home
      (privacy zone + trim). The app has no screen that shows another
      person's shared route, so the developer checks the stored copy on
      staging (`DEVICE_TEST_PLAN.md` D3.18).
