# Security recheck

Written 2026-10-25 to 2026-10-27, against `origin/main` 2ea1576 and then 2addf20 (#30 added docs only). All database checks ran on a local Postgres 16 with Supabase stubs, using port 55464 and data directory `/tmp/pgdata-priv`. Nothing touched a hosted project. Swift was not compiled.

## 1. Local harness

Command:
```
REPO=<worktree>/supabase bash scratchpad/pg/run_priv.sh
```
This is a copy of the shared `run.sh`, changed only to use `D=/tmp/pgdata-priv`, `PORT=55464` and its own log file.

Result: "migrations ok", then every pgTAP file passed. 330 assertions in all:

| File | Passed | File | Passed |
|---|---|---|---|
| 001 | 47 | 010 | 6 |
| 002 | 24 | 011 | 2 |
| 003 | 44 | 012 | 24 |
| 004 | 20 | 013 | 22 |
| 005 | 24 | 014 | 27 |
| 006 | 21 | 015 | 16 |
| 007 | 9 | 016 | 14 |
| 008 | 8 | 017 | 7 |
| 009 | 15 | | |

## 2. Catalog and second-user probes

These are ad hoc queries, run in a rolled-back transaction.

| Check | Result |
|---|---|
| RLS on every table in `public` | **28 of 28 enabled** |
| Tables without RLS in `public` or `storage` | Only `storage.buckets`. That table is a local stub; on hosted projects it is Supabase's own and has RLS. |
| `private` schema | No table grants to anon or authenticated. Authenticated has USAGE, which RLS policy helpers need. `private` isn't an exposed PostgREST schema. |
| SECURITY DEFINER functions without a `search_path` setting | **0** of 72 (42 in `public`, 30 in `private`). All use `search_path = ''`. |
| `public` functions anon can EXECUTE | **0** |
| `public` tables anon has any privilege on | **0** |
| Definer functions that never reference `auth.uid()` | Each one gates through `can_view*`, `private.drive_visible` or `inbox()`, all of which check the caller. Examples: `can_view_post/meet/vehicle/drive`, `like_count`, `comment_count`, `going_count`, `interested_count`, `unread_message_counts`. `dm_purge`, `dm_orphaned_media` and `take_function_slot` aren't executable by authenticated. |
| Buckets | avatars (5 MB), vehicle-media (15 MB), post-media (100 MB, images and mp4/quicktime) and dm-media (10 MB). **All private**, each with a mime allowlist. |

Second-user probe. User B is a stranger to A. A has a private profile, a bio, a privacy zone, a public vehicle, a device token and an avatar object.

| B tries | Result |
|---|---|
| Read A's `profiles` row | **Visible:** username, display name, avatar path, `visibility = private` |
| Read A's `profiles.messaging_suspended_until` | **Readable** (see S2) |
| Read `profile_details` | 0 rows |
| Read `privacy_settings`, `privacy_zones` or `notification_preferences` | 0 rows each |
| Read `device_tokens` | 0 rows (and direct INSERT is `permission denied`) |
| Read A's public-flagged vehicle under a private profile | 0 rows (the profile ceiling applies) |
| Read A's avatar object | Visible (avatars are readable by any signed-in user) |
| Call `get_profile(A)` | Identity fields with `can_view_content: false`; bio and country blanked |
| Search usernames starting "al" | Finds A |
| Write into A's avatar folder | Refused (RLS) |
| Read `drive_tracks`, `private.route_trim_extra`, `private.drive_cells` | 0 rows, permission denied, permission denied |
| A reads B after B blocks A | 0 rows |

## 3. Findings

Highest severity first.

| # | Sev | Finding | Owner |
|---|---|---|---|
| S1 | Medium | **The two-account API suite has never run against staging.** Blocked: needs the owner's OK to create staging accounts (see §6). | owner |
| S2 | Low–Medium | **Any signed-in user can read `profiles.messaging_suspended_until`**, so they can see whether someone else is suspended. #32 adds `private.account_suspensions`. Check that it also stops exposing this column, for example by revoking column SELECT or moving it. | moderation |
| S3 | Low | A private profile still exposes username, display name and avatar to every signed-in user and to search (core_identity.sql:307-309; storage.sql:167-172). This is by design: messaging and follow requests need it. It is now disclosed in privacy.md. | — (disclosed) |
| S4 | Low | **Private media was cached on disk.** `AsyncImage` uses `URLCache.shared`, so photos could sit in Caches after sign-out or deletion. **#31 fixes this:** the cache is memory-only and cleared on sign-out and deletion. | account-deletion |
| S5 | Low | Sign-out keeps the account's unsent drive drafts (raw GPS) on the phone. They are filtered by owner, so another account doesn't see them. Deleting the account erases them (#31). | — (disclosed in privacy.md) |
| S6 | Low | Profile search terms reach provider API logs through the query string (PRIVACY_INVENTORY §3.2). There is a proposed RPC patch. | — |
| S7 | Info | The `auth.identities` identity-link guard trigger may not install on hosted projects (accounts.sql:257-263). It is already tracked in docs/SECURITY_REPORT.md. | — |
| S8 | Info | On main, reports cascade-delete with either account. #32 changes this to `SET NULL`. | moderation |
| S9 | Info | No `Package.resolved` is committed, so dependency versions float within 2.x on each build. | release-layout |

## 4. Client checks (read, not run)

**Session**
- The supabase-swift session is kept in the Keychain, service `app.pullup.session`, with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. The legacy item is migrated, and `remove()` deletes both (`PullUpData/SessionKeychain.swift`).
- The Apple user id is kept in the Keychain with the ThisDeviceOnly accessibility.
- Credential revocation is checked on foreground and signs the person out (`App/AppModel.swift:280-289`).

**Account switching** (`App/AppModel.swift:169-179, 301-309`). Sign-out does all of the following:
- unregisters the push token
- signs out on the server
- clears the Apple credential and the exports
- stops messaging, Pro and the garage
- clears the recorder owner

Drafts are kept per owner.

**Drive files**
- Kept in `Application Support/Drives`, excluded from backup, with `completeFileProtectionUntilFirstUserAuthentication`.

**Metadata stripping**
- Photos are re-rendered through `UIGraphicsImageRenderer`, which drops EXIF and GPS (`Garage/VehicleDetailView.swift:269-284`). Avatar, vehicle, post and message uploads all use this path.
- Videos go through a passthrough export with `metadataItemFilter = .forSharing()`, which drops location and device metadata but **keeps audio** (`Feed/PostComposerView.swift:168-173`).

**Shared-route redaction** (20261018000800:69-149):
- Endpoints are trimmed by `route_endpoint_trim_m` (default 400 m, minimum 200 m), plus a random 0–250 m extra kept per drive.
- Points within zone radius + 150 m are dropped.
- The route is thinned to points at least 25 m apart.
- Coordinates are rounded to 4 decimals.
- Changing a zone re-redacts existing routes. Turning sharing off withdraws them.
- pgTAP files 009 and 012 cover this.

**Suspended or deleted accounts**
- On main, suspension covers messaging only; #32 extends it to every write path.
- After deletion, #31 refuses uploads from a token that hasn't expired yet.

## 5. Secrets

| Search | Result |
|---|---|
| `git grep -E 'eyJ[A-Za-z0-9_-]{10,}\.'` | No matches |
| History, all branches: `git log --all -p \| grep -cE 'eyJhbGciOi…\.…'` | 0 |
| `sb_secret_` / `sb_publishable_…` in history | None |
| `sk_live` / `sk_test`, `AKIA`, `ghp_`, `xox[bp]-` | None |
| `BEGIN PRIVATE KEY` | Only `supabase/functions/_shared/appstore_test.ts:20`, which builds a PEM from a key generated at test time. Not a secret. |
| `service_role` in `native/` | **None** |
| `service_role` elsewhere | Only edge functions, migrations, tests and workflows, which read it from the environment |
| Committed `.p8`, `.p12`, `.pem`, `.mobileprovision`, `.env` or `Secrets.xcconfig` | None. All are gitignored. |

`native/ios/Config/Secrets.example.xcconfig` holds placeholders only. `Base.xcconfig` leaves the host and anon key empty.

## 6. Blocked: two-account API test on staging

**Blocked: needs the owner's OK to create staging accounts.** The suite creates and deletes **three** synthetic users, Ann, Ben and Cat (`pullup-api-<run>-<name>@example.com`), with the service role key, and refuses any target other than `local` or `staging` (`supabase/tests/api/two_accounts_test.ts:1-55`).

**How CI runs it.** The suite runs inside `Supabase deploy` (`.github/workflows/supabase-deploy.yml:247-264`), only when `apply` is ticked and the environment is staging.
- **That same run also applies migrations and deploys functions to staging.** So the test can't be run on its own from the workflow. Start it with:
  ```
  gh workflow run supabase-deploy.yml -f environment=staging -f apply=true
  ```
- Or, from the owner's own machine, without deploying:
  ```
  PULLUP_API_TARGET=staging PULLUP_API_URL=https://<staging-ref>.supabase.co \
  PULLUP_API_ANON_KEY=<anon or publishable key> PULLUP_API_SERVICE_ROLE_KEY=<service or secret key> \
    deno test --config supabase/functions/deno.json --allow-env --allow-net supabase/tests/api/
  ```

The same suite runs against the local stack on every backend CI run (`.github/workflows/supabase.yml:60-80`).
