# Security report (Phase 1 database)

Findings in the Phase 1 schema (this branch, PR #2) from the security
assessment done in Phase 2 (PR #3), 2026-10-17. The full Phase 2 report,
which also covers messaging, Pro and push, is on `claude/pull-up-phase-2`.

## Scope and method

* **Systems:** only Pull Up's own code: the Postgres schema, RLS policies and
  functions. No hosted Supabase project was touched and nothing was sent to
  any third party.
* **Environment:** the local Supabase stack that CI starts
  (`supabase db start`) and a local Postgres 16 copy with synthetic users
  (`*@example.com`).
* **Checklists:** OWASP MASVS v2 and the OWASP API Security Top 10 (2023),
  applied by reading every migration, policy and function, then writing a
  failing test for each suspected weakness before fixing it.
* **Regression tests:** `supabase/tests/006_security_surface.sql` (17 tests;
  9 failed before the fix and pass after it), alongside
  `001_privacy_and_rls.sql`.

Not covered, and not claimed: a hosted Supabase project, real devices,
network interception, binary hardening and load testing.

## Summary

| ID | Severity | Finding | Status |
| --- | --- | --- | --- |
| SEC-01 | High | Owner-rights helpers callable by any signed-in user: read the route of anyone's private drive; forge notifications (and pushes) from anyone to anyone | Fixed, `20261016000800` |
| SEC-02 | Medium | Anyone could ask who has blocked whom, and whether two private accounts are friends | Fixed, `20261016000800` |
| SEC-04 | Medium | Every public function was executable signed out (Postgres' default PUBLIC grant) | Fixed, `20261016000800` |

(SEC-03 and SEC-05 to SEC-07 concern Phase 2 code and are fixed there.)

## Findings

### SEC-01 (High): internal helpers callable directly

`private.build_shared_route`, `private.notify` and `private.validate_drive`
are `SECURITY DEFINER` (they run with the owner's rights, bypassing RLS)
and are meant to be called only by triggers and `share_drive_route`.
Postgres grants `EXECUTE` to `PUBLIC` by default, so any signed-in user
could call them with arbitrary ids:

* `select private.build_shared_route('<someone's drive id>')` returned the
  trimmed route of a **private** drive (API1: broken object level
  authorization).
* `select private.notify('<victim>', '<anyone>', 'follow')` created a
  notification that appears to come from anyone, and once the push webhook
  is set up, a push "Maya started following you" to any account.
* `private.validate_drive` disclosed another drive's validation result.

**Fix:** `EXECUTE` revoked from `public`, `anon` and `authenticated` on all
three. Their callers are owner-rights functions, so they keep working.
**Evidence:** tests 1–3; test 14 fails if a private owner-rights helper
becomes callable by signed-in users again.

### SEC-02 (Medium): relationship oracles

`public.is_blocked_between(a, b)` and `public.is_friend(a, b)` answered for
any two people, so anyone could learn that Ann blocked Cat, or that two
private accounts follow each other (API3; MASVS-PRIVACY).

**Fix:** both now answer only when the caller is `a` or `b`, or when there
is no signed-in user (server, cron). Every internal caller passes the
requester as one of the two, so blocking, feeds and leaderboards behave the
same; `001_privacy_and_rls.sql` still passes. **Evidence:** tests 4–8.

### SEC-04 (Medium): everything callable signed out

25 public functions were executable by `anon`, including the oracles above
and `drive_history_ceiling` (someone's drive-history privacy setting).
Nothing in the app calls the API signed out and every policy targets
`authenticated`. **Fix:** `EXECUTE` revoked from `public` and `anon` on each
of them, with signed-in and server access kept explicitly; the grants
removed are recorded in `private.revoked_anon_execute` so the rollback
restores exactly them. **Evidence:** tests 9–11. Test 11 fails if a future
migration adds a public function without revoking anon.

## Controls verified (unchanged, with tests)

* Every public table has RLS on; every owner-rights function pins
  `search_path`; every policy targets signed-in users; anon can't reach the
  private schema and no storage bucket is public (tests 12–17).

## Still to do

* Run `supabase test db` against the staging project once it exists.
