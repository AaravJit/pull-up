# Staging deployment record

First deployment of the Pull Up backend to the hosted staging project,
2026-10-18 (UTC). Done through the Supabase connector, not the
`Supabase deploy` workflow: the repository has no Supabase access token or
database password yet (`SUPABASE_SETUP.md` §2–3). The workflow can take over
from here, because every migration was recorded under its own version in
`supabase_migrations.schema_migrations`, exactly as `supabase db push` does.

## Project

| | |
| --- | --- |
| Name | `pull-up-staging` |
| Project ref | `hllfsfbuexuniosdewob` |
| Organization | Pull Up (`vajtpzqarpjmydzcsumj`) |
| Region, engine | us-east-1, Postgres 17.11 |
| API URL | `https://hllfsfbuexuniosdewob.supabase.co` |

It was the only project the connector could see when the work started, so
nothing else was touched (in particular not `veyora-dev`).

## Before

The project was new and empty: no auth users, no storage buckets or files,
no tables in `public`, no Edge Functions, no Vault secrets. There was no data
to back up. The snapshot is in the project files (`staging/pre-deploy-snapshot-2026-10-18.md`).

## What was deployed

**Migrations (20).** Everything on `main` plus the open Phase 3 PRs, applied
in version order, each in one transaction. Each file was fetched from a pushed
commit and its MD5 checked against the reviewed file before it ran.

| Versions | From |
| --- | --- |
| 20261016000100 – 20261017000500 (13) | `main` (515ec98) |
| 20261018000100 email signup guard | PR #6, M2 |
| 20261018000200 function rate limits | PR #7, M5 |
| 20261018000300 push guard | PR #10, M6 |
| 20261018000400 – 000600 drive privacy, notification limits, storage moves | PR #14, M10 |
| 20261018000700 explicit API grants | this PR (#4, M1), new |

On 2026-10-18 staging therefore ran code that wasn't on `main` yet.
Superseded: all of those PRs have since merged, and after the third
deployment (below) staging has 24 migrations, all on `main`.

After applying, a fingerprint of every function, policy, column, trigger,
bucket and grant in `public`, `private` and `storage` matched the same
migrations run locally.

**Storage buckets (4), all private:** `avatars` (5 MB), `vehicle-media`
(15 MB), `post-media` (100 MB), `dm-media` (10 MB), with 9 storage policies.

**Edge Functions (5):** `delete-account`, `verify-subscription`,
`send-push`, `dm-retention` with JWT verification on;
`app-store-notifications` with it off (Apple sends no Supabase token), as
`supabase/config.toml` says.

**Auth triggers:** `on_auth_user_created` and `pullup_identity_link_guard`
are both installed.

## Compatibility problem found and fixed

On this project, tables created in `public` get **no** SELECT, INSERT,
UPDATE or DELETE for `anon`, `authenticated` or `service_role` by default.
The local stack (and so CI) still has the old default that granted them, and
the migrations relied on it. Result on staging: every table answered
"permission denied", Edge Functions included, and 9 of 11 pgTAP files failed.

`20261018000700_explicit_api_grants.sql` grants what the old default gave and
then repeats the earlier revokes. It was reproduced locally first by giving
the local stub the hosted defaults: without the migration the same 9 files
fail, with it all pass, and the rollback suite still passes. Any future table
needs its own grants in its migration.

## Tests on staging

**Database (pgTAP), 207 of 207 passed.** All 11 files, `supabase/tests/001`
to `011`, ran inside the hosted database in one transaction that was always
rolled back, so nothing they wrote was kept.

**Cross-account API checks, 133 of 133 passed.** Three synthetic accounts
(`pullup-api-<run>-ann|ben|cat@example.com`, random passwords never shown or
stored outside the database) signed in through the real Auth API and used
the real REST, Storage and Edge Function endpoints with their own tokens.
These are the scenarios of `supabase/tests/api/two_accounts_test.ts`:

| Area | Checks |
| --- | --- |
| Signed out gets nothing | 3 |
| Profiles, usernames, onboarding, avatar folder | 15 |
| Garage visibility, vehicle photos | 10 |
| Drive upload, server validation, private drives and GPS tracks | 11 |
| Follows and notifications | 6 |
| Posts, likes, comments | 10 |
| Meets, RSVPs, cancellation | 7 |
| Messages, requests, photos, reactions, read receipts, unsend, mute | 32 |
| Shared items follow the owner's current privacy | 9 |
| Blocking | 6 |
| Push tokens on a shared phone | 6 |
| Pro can't be granted from the phone; rate limit 10 a minute | 7 |
| Functions without their secrets refuse | 4 |
| Account deletion through `delete-account` | 5 |
| Clean-up through `delete-account` | 2 |

All three accounts were deleted through `delete-account`; afterwards staging
had 0 auth users and 0 stored files.

**Not covered here:**

* Realtime delivery of messages. It needs a WebSocket client; the Deno suite
  covers it and runs against staging from the deploy workflow once the
  repository has staging credentials.
* "Nobody can register with email from outside". The before-user-created hook
  isn't enabled on staging yet (dashboard step below), and a public sign-up
  attempt would have sent a confirmation email.
* Sign in with Apple, APNs delivery, App Store purchases: no Apple
  credentials exist yet.

## Supabase advisors after deployment

Security: no errors.

* 39 warnings "security definer function executable by signed-in users".
  These are the app's RPCs and are meant to be callable. Two are not fine,
  see the findings below.
* 2 notes "RLS enabled, no policy" on `public.app_store_notifications` and
  `private.function_calls`: intended, both are service role only.
* 4 warnings on `selftest.*` functions: temporary test helpers, to be
  removed (below).

Performance (not blocking): 55 policies call `auth.uid()` per row instead of
`(select auth.uid())`, 18 foreign keys without an index, 2 tables with two
permissive SELECT policies.

## Security findings

Superseded by the second deployment below: everything listed here as open
on the first day is fixed in `20261018000800` (PR #14) and on staging.

One correction. The first version of this record listed **G12**,
`is_friend(a, b)` and `is_blocked_between(a, b)` answering for any two
people. That was wrong: both already answer only when the caller is one of
the two (SEC-02, `20261016000800`), and staging's copies do the same. The
advisor flags every owner-rights function callable by signed-in users; it
doesn't read what they check.

## Temporary items

All removed. Aarav ran the clean-up SQL on 2026-10-18; afterwards staging
had no `http` or `pgtap` extension, no `selftest` schema, no
`private.selftest_accounts`, and 0 auth users, identities, sessions,
refresh tokens, stored files, profiles, device tokens, entitlements, rate
limit rows and Vault secrets.

The later test runs below created nothing that outlived them: each ran in
one transaction that always rolled back, the test extensions included.

## Second deployment, 2026-10-18

* Migration `20261018000800_security_open_findings` (PR #14, commit
  `ae96329`), checksum-verified before it ran and recorded under its own
  version. It closes the row-argument counts, G2, G5, G7 and G13.
* Edge Functions `dm-retention` (version 2, deletes orphaned DM photos) and
  `app-store-notifications` (version 2, checks Apple's JWS signature, G8).
  Neither could be called from here; both answer 503 until their secrets
  exist, so their new code paths haven't run on staging.
* Every migration on staging now matches the repository byte for byte
  (MD5 of all 21 compared with the merged branches; 24 after the third
  deployment below).
  `supabase/applied/staging.sha256` records them, and backend CI refuses a
  change to any of them or a new migration numbered below the newest one
  applied (`supabase/scripts/check-applied-migrations.sh`).

**Database tests on staging: 190 of 190 passed** (rolled back): files 001,
002, 003, 005, 006, 007, 008, 011 and 012 (21 of its 22 checks).

Not run on staging this time, and why: the Supabase connector holds back
any SQL containing a delete or drop for a confirmation that can't be given
from this session. Files 004, 009 and 010, check 22 of 012, and the
two-account API suite (which has to remove its accounts afterwards) need
that. All of them pass locally on a copy with staging's default privileges,
and they ran on staging in the first deployment except 012. They run in full
from the `Supabase deploy` workflow (on `main`, started by hand) once the
repository's `staging` environment has `SUPABASE_ACCESS_TOKEN` and
`SUPABASE_DB_PASSWORD`.

Superseded for pgTAP: the third deployment below ran all 14 files on
staging, 004, 009, 010 and check 22 of 012 included. Only the two-account
API suite is still to be rerun.

Advisors after: no security errors; `rls_auto_enable` no longer listed.

## Third deployment, 2026-10-20

On Aarav's approval ("Merge both, deploy"), after #17 and #16 merged
(`main` at `41cf1d5`):

| Version | From | MD5 on staging = repository |
| --- | --- | --- |
| `20261020000100_signup_hook_schema_usage` | #6 | `8d40649a…` |
| `20261020000200_drive_distance_bounds` | #13 | `1d452ad3…` |
| `20261020000300_leaderboard_ranked_distance` | #16 | `4a4d548f…` |

Each ran through the connector in one block that refused to run unless the
file's MD5 matched and the version wasn't already recorded, then recorded it
under its own version. Staging now has 24 migrations, all on `main`, and
none from open pull requests. Staging held no users, drives or files, so
000300's backfill had nothing to score.

**Database tests on staging: 262 of 262 passed** (rolled back): all 14 files,
`supabase/tests/001` to `014` at `41cf1d5`, fetched by commit and checked by
MD5. This includes 004, 009, 010 and check 22 of 012, which the connector
ran this time.

**API smoke checks, signed out, through the real REST API:** the leaderboard
and `drives` refuse with 401, while `drive_scores`, `track_coverage_m` and
`validate_drive` aren't exposed (404). `supabase_auth_admin` has usage on
`public`. Signed-in users can call the leaderboard, but can't read
`private.drive_scores` or call `track_coverage_m`.

The two-account API suite was **not** rerun. It creates real accounts
outside any transaction and has to delete them afterwards, and its clean-up
needed a hand in the SQL editor the first time. None of the three
migrations changes what it covers, apart from the leaderboard, which pgTAP
014 tests. It runs from the `Supabase deploy` workflow once step 7 below is
done.

Afterwards: 0 auth users, profiles, drives, notifications, scores and stored
files. Neither `http` nor `pgtap` is installed, and no `selftest` objects
are left. Security advisors: no errors, and the same intended warnings as
before (38 app RPCs callable by signed-in users, two service-role tables
with no policies).

Auth settings read from `/auth/v1/settings`: Apple is **off**, email sign-in
is on and public sign-up is not disabled. Dashboard steps 1 and 4 below are
still open, and the first TestFlight run waits on them.

## Dashboard steps still needed (`SUPABASE_SETUP.md` §5)

Not doable from the connector, or they need secrets that don't exist yet:

1. Auth ▸ Hooks: enable **Before User Created** with
   `public.hook_before_user_created` (blocks public email and phone sign-ups).
   Until then anyone with the anon key can create an email account on
   staging, since email sign-in is on and public sign-up isn't disabled.
2. Auth ▸ Sign In / Providers: turn on **Allow manual linking**.
3. Auth ▸ URL Configuration: add redirect URL `pullup://auth-callback`.
4. Auth ▸ Providers ▸ Apple: needs the Services ID and Sign in with Apple
   key.
5. Function secrets `PUSH_WEBHOOK_SECRET` and `CRON_SECRET`, then the
   Database Webhook (INSERT on `public.notifications` → `send-push`) and the
   daily Cron job (→ `dm-retention`). Enabling Database ▸ Webhooks installs
   `pg_net` (both need it) and enabling Integrations ▸ Cron installs
   `pg_cron`. `send-push` checks the `x-pullup-webhook-secret` header
   against `PUSH_WEBHOOK_SECRET`, `dm-retention` checks
   `x-pullup-cron-secret` against `CRON_SECRET`, and both keep JWT
   verification on, so each call also sends `Authorization: Bearer <anon
   key>`. Keep `CRON_SECRET` in Vault and have the job read it rather than
   pasting it into the SQL (`SUPABASE_SETUP.md` §5 has the job).
6. Function secrets from Apple: `APNS_*`, `APPLE_*`, `APPSTORE_*`.
7. GitHub environment `staging` with `SUPABASE_PROJECT_REF`,
   `SUPABASE_ACCESS_TOKEN` and `SUPABASE_DB_PASSWORD`, so later deploys and
   the full Deno API suite run from the workflow. It never runs on its own:
   someone with write access to the repository then runs Actions ▸
   Supabase deploy ▸ `staging`, a dry run first, then with apply ticked.
