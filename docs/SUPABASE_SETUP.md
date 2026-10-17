# Supabase setup (staging and production)

How to connect Pull Up to hosted Supabase projects. Steps marked **You**
need the project owner's Supabase or GitHub account; everything else is
done by the "Supabase deploy" workflow.

Nothing here has been run against a hosted project yet. The migrations,
functions and tests have only run on the local Supabase stack in CI.

## What lives where

| Thing | Source of truth | Applied by |
| --- | --- | --- |
| Tables, policies, functions, triggers, storage buckets and their policies, realtime publication | `supabase/migrations/` | `supabase db push` in the deploy workflow |
| Edge functions | `supabase/functions/` | `supabase functions deploy` in the deploy workflow |
| Function secrets (push, Apple, App Store) | GitHub environment secrets | copied by the deploy workflow when present |
| Auth providers, sign-up switches, redirect URLs, database webhook, cron | Supabase dashboard | **You**, once per project (step 5) |
| App's project URL and anon key | GitHub environment secrets, or your local `Config/Secrets.xcconfig` | the iOS build |

The anon key is meant to be public; row-level security protects the data.
The service-role key and database password never go in the app or in git.

## 1. Create the projects (**You**)

1. In the Supabase dashboard, create a project named `pull-up-staging`.
   Choose a region near you and save the database password in your password
   manager.
2. Later, before inviting real users, create `pull-up-production` the same
   way. A free organization only allows a limited number of active
   projects, and your current organization already has `veyora-dev`, so
   production may need a paid plan; check supabase.com/pricing first. Keep
   Pull Up's projects out of the Veyora project.
3. Note each project's **ref**: the part before `.supabase.co` in Project
   Settings ▸ API ▸ Project URL.

## 2. Create an access token (**You**)

Account ▸ Access Tokens ▸ Generate new token, named `pull-up github
deploy`. It acts as you, so store it only as a GitHub secret (next step).

## 3. Add GitHub environments (**You**)

Repository ▸ Settings ▸ Environments ▸ New environment:

| Environment | Variables | Secrets | Protection |
| --- | --- | --- | --- |
| `staging` | `SUPABASE_PROJECT_REF` = staging ref | `SUPABASE_ACCESS_TOKEN`, `SUPABASE_DB_PASSWORD` (staging's) | none |
| `production` | `SUPABASE_PROJECT_REF` = production ref | `SUPABASE_ACCESS_TOKEN`, `SUPABASE_DB_PASSWORD` (production's) | **Required reviewers: you**; deployment branches: `main` only |

Optional secrets, per environment, copied to the project's function
secrets on each deploy. Functions answer "not configured" without them.

| Secret | Used by | Where it comes from |
| --- | --- | --- |
| `PUSH_WEBHOOK_SECRET` | `send-push` | `openssl rand -hex 32`; the same value goes in the webhook (step 5) |
| `CRON_SECRET` | `dm-retention` | `openssl rand -hex 32`; the same value goes in the cron job (step 5) |
| `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_PRIVATE_KEY`, `APNS_TOPIC` | `send-push` | Apple push key (`RELEASE_CHECKLIST.md` §3) |
| `APPLE_CLIENT_ID`, `APPLE_KEY_ID`, `APPLE_TEAM_ID`, `APPLE_PRIVATE_KEY` | `delete-account` (Apple token revocation) | Sign in with Apple key (§3) |
| `APPSTORE_ISSUER_ID`, `APPSTORE_KEY_ID`, `APPSTORE_PRIVATE_KEY`, `APPSTORE_BUNDLE_ID` | `verify-subscription`, `app-store-notifications` | App Store Server API key (§4a) |

## 4. Deploy (workflow)

Actions ▸ **Supabase deploy** ▸ Run workflow. (GitHub lists a hand-run
workflow only once it is on `main`, so this appears after PR #2 is merged.)

1. `staging`, **apply unticked**. This is a dry run: it lists the migrations
   staging doesn't have yet and refuses any that could drop data
   (`supabase/scripts/check-pending-migrations.sh`).
2. `staging`, **apply ticked**. Applies the migrations, copies the function
   secrets, deploys the functions, then runs against staging:
   * the pgTAP suite (`supabase/tests/*.sql`), which rolls back everything
     it writes, and
   * the two-account API tests (`supabase/tests/api/`): three throwaway
     `pullup-api-…@example.com` accounts exercise sign-in, profiles,
     garage, photos, drives, feed, meets, messages, realtime, push tokens,
     Pro and account deletion, then delete themselves.
3. `production`: dry run first, then apply. It waits for your approval and
   runs no tests that write data.

## 5. Dashboard settings per project (**You**)

These aren't in migrations because they hold per-project values:

* **Auth ▸ Providers ▸ Email:** keep enabled. It's needed for the App
  Review demo account (create it under Auth ▸ Users) and for the staging
  API tests. Don't turn off "Allow new users to sign up": that switch
  covers every provider, so it would stop new Sign in with Apple accounts
  too. The app offers no email sign-up.
* **Auth ▸ Hooks ▸ Before User Created:** enable it with type Postgres and
  the function `public.hook_before_user_created`. It refuses new email and
  phone accounts from the public sign-up endpoint, so registering takes
  Sign in with Apple; accounts you create under Auth ▸ Users still work.
  Check it: a sign-up from the API with the anon key must fail with
  "New Pull Up accounts are created with Sign in with Apple."
* **Auth ▸ Providers ▸ Apple:** enable with the Services ID and key
  (`RELEASE_CHECKLIST.md` §3).
* **Auth ▸ Sign In / Providers:** "Allow manual linking" on (the database
  refuses links the person didn't start).
* **Auth ▸ URL Configuration:** site URL and redirect URL
  `pullup://auth-callback`.
* **Database ▸ Webhooks:** on INSERT into `public.notifications`, POST to
  the `send-push` function with header
  `x-pullup-webhook-secret: <PUSH_WEBHOOK_SECRET>`.
* **Integrations ▸ Cron:** daily POST to `dm-retention` with header
  `x-pullup-cron-secret: <CRON_SECRET>`.
* Check the account-linking guard is installed (SQL editor):
  `select tgname from pg_trigger where tgname = 'pullup_identity_link_guard';`
  must return one row.

## 6. Point the app at a project

* **Your own build:** copy `native/ios/Config/Secrets.example.xcconfig` to
  `Secrets.xcconfig` and set `PULLUP_SUPABASE_HOST` (`<ref>.supabase.co`),
  `PULLUP_SUPABASE_ANON_KEY` (Project Settings ▸ API) and
  `PULLUP_BACKEND_ENVIRONMENT` (`staging` or `production`). Settings ▸
  About then shows "Pull Up server (staging)" on staging builds.
* **TestFlight builds:** the release workflow writes the same file from
  the GitHub environment it builds for (`TESTFLIGHT_SETUP.md`).

## Rolling back

Each migration has a reverse script in `supabase/rollback/`. CI applies
all of them in reverse and re-applies the migrations on every push. A
rollback that would delete data refuses to run unless
`pullup.allow_destructive_rollback` is set for the session, so run them by
hand in the SQL editor only after a backup (Database ▸ Backups).
