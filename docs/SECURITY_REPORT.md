# Security report (Phase 2)

Assessment of the Pull Up native iOS app and its Supabase backend on branch
`claude/pull-up-phase-2` (PR #3, stacked on PR #2), 2026-10-17.

## Scope and method

* **Systems:** only Pull Up's own code: the Postgres schema, RLS policies and
  functions, the edge functions, and the iOS client source. No hosted
  Supabase project, App Store, APNs or eBay system was touched, and nothing
  was sent to any third party.
* **Environment:** the local Supabase stack that CI starts
  (`supabase db start`) and a local Postgres 16 copy with synthetic users
  (`*@example.com`). Edge functions run under Deno with Apple and APNs
  stubbed.
* **Checklists:** OWASP MASVS v2 (storage, crypto, auth, network, platform,
  code, privacy) and the OWASP API Security Top 10 (2023), applied by
  reading every migration, policy and function, then writing a failing test
  for each suspected weakness before fixing it.
* **Regression tests:** each finding has a pgTAP test that failed before the
  fix and passes after it: `supabase/tests/006_security_surface.sql`
  (20 tests), plus the earlier suites (`001`–`005`, 159 tests) and the Deno
  tests in `supabase/functions/_shared/`.

Not covered, and not claimed: a hosted Supabase project, real devices,
network interception or certificate handling on a phone, binary
hardening or jailbreak resistance, and load testing. See "Still to do".

## Summary

| ID | Severity | Finding | Introduced | Status |
| --- | --- | --- | --- | --- |
| SEC-01 | High | Owner-rights helpers callable by any signed-in user: read the route of anyone's private drive; forge notifications (and pushes) from anyone to anyone | PR #2 | Fixed in PR #2, `20261016000800` |
| SEC-02 | Medium | Anyone could ask who has blocked whom, and whether two private accounts are friends | PR #2 | Fixed in PR #2, `20261016000800` |
| SEC-03 | Low | DM helpers answered "who is in conversation X" for any caller who knew its id | PR #3 (M2) | Fixed, `20261017000500` |
| SEC-04 | Medium | Every public function was executable signed out (Postgres' default PUBLIC grant) | PR #2 | Fixed in PR #2, `20261016000800`; Phase 2 functions in `20261017000500` |
| SEC-05 | Medium | A phone's push token stayed with the previous account after someone else signed in, so their notifications kept arriving there | PR #2 | Fixed in M5, `20261017000400` |
| SEC-06 | Low | Opening a message request told the sender it had been read | PR #3 (M2) | Fixed in M2 (`4553118`) |
| SEC-07 | Low | GPX/CSV exports of a full route were written without file protection and piled up in tmp | PR #3 (M3) | Fixed (client) |
| R-1 | Accepted | Direct messages are not end-to-end encrypted | Design | Disclosed in the app |
| R-2 | Accepted | A modified client can show Pro looks locally | Design | Server holds the truth |
| R-3 | Residual | `app-store-notifications` is a public URL that can make the server call Apple | Design | Validated; quota risk |
| R-4 | Residual | No per-user rate limit on `verify-subscription` | M3 | Add before launch |

## Findings

### SEC-01 (High): internal helpers callable directly

`private.build_shared_route`, `private.notify` and `private.validate_drive`
are `SECURITY DEFINER` (they run with the owner's rights, bypassing RLS)
and are meant to be called only by triggers and `share_drive_route`. The
`private` schema is usable by signed-in users (policies need some of its
helpers), and Postgres grants `EXECUTE` to `PUBLIC` by default, so any
signed-in user could call them with arbitrary ids:

* `select private.build_shared_route('<someone's drive id>')` returned the
  trimmed route of a **private** drive (API1: broken object level
  authorization). Drive ids are UUIDs, but they appear in feeds and shared
  cards for public drives, and privacy settings can change after.
* `select private.notify('<victim>', '<anyone>', 'follow')` created a
  notification that appears to come from anyone, and once the push webhook
  is set up, a push "Maya started following you" to any account
  (impersonation and spam).
* `private.validate_drive` disclosed another drive's validation result.

**Fix:** `EXECUTE` revoked from `public`, `anon` and `authenticated` on all
three. Their callers are owner-rights functions, so they keep working.
**Evidence:** tests 1–3 in `006_security_surface.sql` failed before the
migration ("caught: no exception") and pass after; test 17 now pins the
list of private owner-rights helpers signed-in users may call, each of
which answers only about the caller.

### SEC-02 (Medium): relationship oracles

`public.is_blocked_between(a, b)` and `public.is_friend(a, b)` answered for
any two people. Profile ids are visible, so anyone could learn that Ann
blocked Cat, or that two private accounts follow each other (API3: broken
object property level authorization; MASVS-PRIVACY).

**Fix:** both now answer only when the caller is `a` or `b`, or when there
is no signed-in user (server, cron). Every internal caller already passes
the requester as one of the two, so blocking, feeds, leaderboards and
messaging behave the same; the existing 159 tests still pass. **Evidence:**
tests 4–9.

### SEC-03 (Low): DM membership helpers

`private.peer_of` and `private.is_member` (used by message policies)
returned the members of any conversation id. Conversation ids can't be
listed by non-members (tested in `003`), so this needed a leaked id.
**Fix:** they answer only about the caller. **Evidence:** tests 10–11.

### SEC-04 (Medium): everything callable signed out

25 public functions were executable by `anon`, including the oracles above
and `drive_history_ceiling` (someone's drive-history privacy setting).
Nothing in the app calls the API signed out and every policy targets
`authenticated`. **Fix:** `EXECUTE` revoked from `public` and `anon` on each
of them, with signed-in and server access kept explicitly; the exact grants
removed are recorded in `private.revoked_anon_execute` so the rollback
restores them. `20261016000800` (in PR #2) does this for the Phase 1
functions and `20261017000500` for the ones Phase 2 adds, each recording
its own rows. **Evidence:** tests 12–14. Test 14 fails if a future
migration adds a public function without
`revoke execute ... from public, anon`.

### SEC-05 (Medium): push tokens on shared phones

Tokens were upserted directly into `device_tokens`. When a second account
signed in on the same phone, RLS rejected the update of the first
account's row, so the first account kept the token and its pushes kept
arriving. **Fix (M5):** writes go through `register_device_token`, which
moves the token to whoever registered it last, keeps 10 phones per account
and validates the format; direct inserts and updates are revoked; sign-out
unregisters the phone. **Evidence:** `005_notification_preferences.sql`
tests 19–24 and `PushFlowTests`.

### SEC-06 (Low): read receipts on requests

Opening a message request reported a read time to the stranger who sent
it. Fixed in M2; covered by "opening a request sends no read receipt" in
`003_direct_messages.sql`.

### SEC-07 (Low): exported routes on disk

Pro track exports contain the full route, protected places included (the
app says so). They are now written with
`completeFileProtectionUntilFirstUserAuthentication`, like saved drives,
and each new export replaces the previous one. Not verified on a device.

## Accepted and residual risks

* **R-1 Direct messages are not end-to-end encrypted.** They are protected
  by RLS, TLS and Supabase's encryption at rest, and readable by the
  service role. The conversation screen says so. Pushes carry no message
  text unless the person turns previews on, and never for requests.
* **R-2 Client-side Pro looks.** The Ring face and Pro accents are unlocked
  on the device from the server's entitlement; a patched app could show
  them without paying. They are cosmetic. The entitlement itself is written
  only by the server after Apple confirms the transaction (`004`), and the
  server never trusts the client's signed transaction.
* **R-3 Public notification endpoint.** App Store Server Notifications must
  reach a public URL. The function checks the bundle id, notification id
  and signing date, deduplicates, and re-fetches the subscription from Apple
  rather than trusting the payload. A flood could still spend App Store
  Server API quota. Mitigation if needed: verify the JWS certificate chain
  before calling Apple.
* **R-4 Rate limits on edge functions.** `verify-subscription` has no
  per-user limit. Add one (for example 10 calls per user per hour, in a
  table) before launch.
* **Unbound purchases are refused.** A transaction without the user's id as
  `appAccountToken` never grants Pro, so one Apple subscription can't be
  shared across accounts.

## Controls verified (unchanged, with tests)

* Every public table has RLS on; every owner-rights function pins
  `search_path`; every policy targets signed-in users; no storage bucket is
  public (`006` tests 15–20).
* Account linking never merges on matching email; it needs a fresh,
  unexpired link request from the signed-in user (`002`).
* Messages: no sending as someone else, no reading or posting outside your
  conversations, conversations not enumerable, one uniform refusal for
  blocks, privacy and missing accounts, rate limits, suspensions, shared
  items re-checked against the recipient (`003`).
* Pro: clients can't insert, update or extend entitlements, and one
  subscription unlocks one account (`004`).
* Push: the webhook needs a shared secret, only the notification id is taken
  from the request, preferences are applied server side (`005`, Deno tests).
* Client: no secrets in the repository (the anon key and service-role key
  are configured outside git), no logging of tokens or message content,
  location history excluded from backups and file-protected, no App
  Transport Security exceptions. Sessions use supabase-swift's default
  storage, which is the Keychain on iOS (not inspected on a device).

## Still to do (needs people or systems outside CI)

* Run `supabase test db` against the staging project once it exists.
* On a device: confirm the session is in the Keychain, exported files are
  protected while locked, and pushes show no message text by default.
* Add the `verify-subscription` rate limit (R-4).
* Re-run this checklist before the App Store submission.
