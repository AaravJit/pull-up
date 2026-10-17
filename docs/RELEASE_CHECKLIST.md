# Release checklist

Everything below needs a person with the Apple Developer account, the
Supabase project, or a physical iPhone. Nothing here can be done from CI
alone. Items are in the order they unblock each other.

## 1. Supabase project

- [ ] Create a Supabase project (or pick the existing one) and note the
      project ref and anon key (Project Settings ▸ API).
- [ ] Link and push the schema from a machine with the Supabase CLI:
      `supabase link --project-ref <ref>` then `supabase db push`.
      All eight migrations are additive. Each has a matching file in
      `supabase/rollback/` (CI rolls every one back and re-applies it), and
      rollbacks that would drop data refuse to run unless
      `pullup.allow_destructive_rollback` is set for the session.
- [ ] Run `supabase test db` against a staging project (the same pgTAP
      suite CI runs).
- [ ] Deploy edge functions: `supabase functions deploy delete-account send-push`.
- [ ] Generate a random push webhook secret (`openssl rand -hex 32`) and
      set it: `supabase secrets set PUSH_WEBHOOK_SECRET=<value>`.
- [ ] Database ▸ Webhooks: on INSERT into `public.notifications`, call the
      `send-push` function with the HTTP header
      `x-pullup-webhook-secret: <same value>`. Requests without it are
      rejected. Without the webhook, notifications still appear in the app's
      bell; they just aren't pushed.
- [ ] Auth ▸ Providers: enable Email (decide whether to require
      confirmation; the app handles both) and Apple (see 3).
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
- [ ] Push notifications end to end (follow from a second account).
- [ ] Photo upload from the library: confirm EXIF GPS is stripped (download
      the stored file and inspect it).
- [ ] Video post playback over cellular.
- [ ] CarPlay on a head unit once the entitlement is granted.
- [ ] Share a route and check from a second account that it starts and ends
      away from home (privacy zone + trim).
