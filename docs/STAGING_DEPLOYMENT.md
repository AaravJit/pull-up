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

Staging therefore runs code that isn't on `main` yet. If one of those PRs
changes a migration before it merges, staging has to be re-applied from the
new version.

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

## Security findings still open

From the Milestone 10 re-check (`SECURITY_REPORT.md`, PR #14): G2 route trim
re-randomised on rebuild, G5 no storage quota per account, G7 photos of
unsent DMs never deleted, G8 App Store notification signature not checked
(the stored state still comes from Apple's API), and the suspected row
argument count functions (`like_count`, `comment_count`, `going_count`,
`interested_count`, `liked_by_me`, `my_rsvp`).

New from the staging advisor:

* **G12. Relationship lookups for any two people.** `public.is_friend(a, b)`
  and `public.is_blocked_between(a, b)` are callable by any signed-in user
  for any two user ids, so someone could learn who has blocked whom, or that
  two private accounts are friends. RLS policies call them, so they can't
  simply be revoked; the fix is to answer only when one of the two is the
  caller.
* **G13. Supabase's own `public.rls_auto_enable()`** is callable through
  `/rest/v1/rpc`. Calling an event-trigger function directly fails, so it
  does nothing, but execute should be revoked from `anon` and
  `authenticated`.

## Temporary items still on staging

The connector stopped running write statements after the tests finished, so
these are still there. Nothing on them is readable through the API:

* the `http` extension, used to fetch the reviewed migration and test files
  from GitHub and to call the API during the tests. Its functions are
  executable by every role but live in the unexposed `extensions` schema;
* schema `selftest` (test helpers and results) and table
  `private.selftest_accounts` (the three deleted accounts' emails, passwords
  and tokens; the accounts no longer exist and the tokens expire within the
  hour).

Remove them in the SQL editor:

```sql
drop extension if exists http;
drop schema if exists selftest cascade;
drop table if exists private.selftest_accounts;
```

## Dashboard steps still needed (`SUPABASE_SETUP.md` §5)

Not doable from the connector, or they need secrets that don't exist yet:

1. Auth ▸ Hooks: enable **Before User Created** with
   `public.hook_before_user_created` (blocks public email and phone sign-ups).
2. Auth ▸ Sign In / Providers: turn on **Allow manual linking**.
3. Auth ▸ URL Configuration: add redirect URL `pullup://auth-callback`.
4. Auth ▸ Providers ▸ Apple: needs the Services ID and Sign in with Apple
   key.
5. Function secrets `PUSH_WEBHOOK_SECRET` and `CRON_SECRET`, then the
   Database Webhook (INSERT on `public.notifications` → `send-push`) and the
   daily Cron job (→ `dm-retention`).
6. Function secrets from Apple: `APNS_*`, `APPLE_*`, `APPSTORE_*`.
7. GitHub environment `staging` with `SUPABASE_PROJECT_REF`,
   `SUPABASE_ACCESS_TOKEN` and `SUPABASE_DB_PASSWORD`, so later deploys and
   the full Deno API suite run from the workflow.
