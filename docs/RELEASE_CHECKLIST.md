# Release checklist

Everything below needs a person with the Apple Developer account, the
Supabase project, or a physical iPhone. Nothing here can be done from CI
alone. Items are in the order they unblock each other.

## 1. Supabase project

- [ ] Create a Supabase project (or pick the existing one) and note the
      project ref and anon key (Project Settings ▸ API).
- [ ] Link and push the schema from a machine with the Supabase CLI:
      `supabase link --project-ref <ref>` then `supabase db push`.
      All thirteen migrations are additive. Each has a matching file in
      `supabase/rollback/` (CI rolls every one back and re-applies it), and
      rollbacks that would drop data refuse to run unless
      `pullup.allow_destructive_rollback` is set for the session.
- [ ] Run `supabase test db` against a staging project (the same pgTAP
      suite CI runs).
- [ ] Deploy edge functions: `supabase functions deploy delete-account send-push
      dm-retention verify-subscription app-store-notifications`.
- [ ] Generate a random push webhook secret (`openssl rand -hex 32`) and
      set it: `supabase secrets set PUSH_WEBHOOK_SECRET=<value>`.
- [ ] Database ▸ Webhooks: on INSERT into `public.notifications`, call the
      `send-push` function with the HTTP header
      `x-pullup-webhook-secret: <same value>`. Requests without it are
      rejected. Without the webhook, notifications still appear in the app's
      bell; they just aren't pushed.
- [ ] Auth ▸ Providers: enable Apple (see 3). Keep Email enabled only for
      App Review and demo accounts, and turn **off** "Allow new users to sign
      up" for email: the app offers email sign-in only, behind "Other sign-in
      options".
- [ ] Confirm the account-linking guard is installed (it stops Supabase
      from merging an Apple sign-in into an email account with the same
      address): `select tgname from pg_trigger where tgname =
      'pullup_identity_link_guard';` must return one row. If `db push`
      printed "pullup_identity_link_guard was not installed", ask Supabase
      support how to add a trigger on `auth.identities` on your plan before
      launch, and keep "Allow manual linking" off meanwhile.
- [ ] Auth ▸ URL configuration: add `pullup://auth-callback` as a redirect URL
      for email confirmation links.

## 2. App configuration (no secrets in git)

- [ ] Copy `native/ios/Config/Secrets.example.xcconfig` to
      `native/ios/Config/Secrets.xcconfig` (gitignored) and fill in
      `PULLUP_TEAM_ID`, `PULLUP_SUPABASE_HOST`, `PULLUP_SUPABASE_ANON_KEY` and,
      if `app.pullup.ios` is taken, `PULLUP_BUNDLE_ID`.
      The anon key is public by design; authorization is enforced by RLS.
      The service-role key must never go in the app.
- [ ] For CI-signed builds, store the same values as repository secrets and
      write `Secrets.xcconfig` in the workflow before `xcodegen generate`.
- [ ] A build without these values shows a "Server not configured" screen
      with an explicit demo-data option. It never shows fake data silently.

## 3. Apple Developer account

- [ ] Register the App ID with capabilities: Sign in with Apple, Push
      Notifications. (CarPlay: see 5.)
- [ ] Sign in with Apple: create a Services ID and a key, then enter the
      Services ID, Team ID, Key ID and private key in Supabase ▸ Auth ▸ Apple.
      The app sends a SHA-256 nonce; Supabase verifies it.
- [ ] APNs: create an APNs auth key (.p8). Set the function secrets with
      `supabase secrets set APNS_KEY_ID=… APNS_TEAM_ID=… APNS_TOPIC=<bundle id>
      APNS_PRIVATE_KEY="$(cat AuthKey_XXXX.p8)"`. The app reports whether its
      token is sandbox or production, and the function routes accordingly.
- [ ] `aps-environment` in `PullUp.entitlements` is `development`. Archive
      builds for TestFlight/App Store get `production` from the distribution
      profile automatically.

## 4. Signing, TestFlight, App Store

- [ ] Create the app record in App Store Connect with the bundle ID.
- [ ] Archive: either on a Mac (`xcodegen generate`, open `PullUp.xcodeproj`,
      Product ▸ Archive), or add a CI job using an App Store Connect API key
      stored as repository secrets (`xcodebuild archive` + `-exportArchive`
      with `-allowProvisioningUpdates`). No signing material is in the repo.
- [ ] App Privacy answers: precise location (app functionality, linked to
      user), photos/videos (user content), email, user ID. No tracking.
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
- [ ] Generate `CRON_SECRET` (`openssl rand -hex 32`), set it with
      `supabase secrets set CRON_SECRET=<value>`, and schedule
      `dm-retention` daily (Integrations ▸ Cron, HTTP request to the function
      with headers `x-pullup-cron-secret: <value>` and
      `Authorization: Bearer <anon key>`).
- [ ] Decide who reviews reports (`public.reports`) and how quickly.
      Suspensions are set by the service role on
      `profiles.messaging_suspended_until`.

Sign in with Apple token revocation (account deletion)

- [ ] `supabase secrets set APPLE_TEAM_ID=… APPLE_CLIENT_ID=<bundle id>
      APPLE_KEY_ID=… APPLE_PRIVATE_KEY="$(cat AuthKey_XXXX.p8)"` using a Sign
      in with Apple key. Without them accounts are still deleted, and the app
      tells the person how to remove Pull Up from their Apple Account.

Pull Up Pro (nothing here is done; prices are placeholders)

- [ ] Accept the Paid Apps agreement and add banking and tax details in
      App Store Connect.
- [ ] Create one subscription group with `app.pullup.pro.monthly` and
      `app.pullup.pro.yearly`. The placeholder prices in the local StoreKit
      file are $3.99 and $29.99; choose real prices yourself. Add the review
      screenshot and description each product needs.
- [ ] Create an In-App Purchase key (Users and Access ▸ Integrations ▸ In-App
      Purchase) and set `supabase secrets set APPSTORE_ISSUER_ID=…
      APPSTORE_KEY_ID=… APPSTORE_BUNDLE_ID=<bundle id>
      APPSTORE_PRIVATE_KEY="$(cat SubscriptionKey_XXXX.p8)"`.
- [ ] App Store Connect ▸ App Information ▸ App Store Server Notifications:
      set both the Production and Sandbox URL to
      `https://<project-ref>.supabase.co/functions/v1/app-store-notifications`,
      Version 2. Send a test notification and check the function log shows it.
- [ ] Publish a privacy policy and set `PULLUP_PRIVACY_POLICY` (without
      `https://`) in `Secrets.xcconfig`. The paywall links Apple's standard
      Terms of Use.
- [ ] Sandbox test on a device with a sandbox Apple Account: buy, renew,
      cancel, refund (via the sandbox settings), Ask to Buy, and restore on a
      second phone. Only then submit the products with the app version.
- [ ] Add the per-user rate limit on `verify-subscription`
      (`SECURITY_REPORT.md` R-4).

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
      `006_security_surface.sql`, and work through "Still to do" in
      `SECURITY_REPORT.md`.

## 5. CarPlay

See `docs/CARPLAY.md`. Request the Driving Task entitlement, enable it on
the App ID, set `PULLUP_ENTITLEMENTS = PullUp/PullUp-CarPlay.entitlements`.

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
- [ ] Share a route and check from a second account that it starts and ends
      away from home (privacy zone + trim).
