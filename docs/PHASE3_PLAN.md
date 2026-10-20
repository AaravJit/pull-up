# Phase 3 plan

Phase 3 turns the simulator-tested app into one the owner can install from
TestFlight on an iPhone 18 Pro Max and use against a hosted Supabase
project. It finishes existing features rather than adding new ones.

Product order stays: driving first, community second, parts discovery third.

## Milestone 0: repository audit (2026-10-17)

| Check | Finding |
| --- | --- |
| `main` | `df5ca10` (merge of PR #1, 2026-08-18). Contains only the Expo app. No `native/`, `supabase/` or `docs/`. |
| PR #2 `claude/native-ios-85igsc` → `main` | **Open, draft, not merged.** Head `05035b3`, 41 commits, 157 files, +26,313 / −1 (the −1 is a comment line in `.gitignore`; the Expo app is untouched). |
| PR #3 `claude/pull-up-phase-2` | Merged 2026-10-17 20:29 UTC **into `claude/native-ios-85igsc`, not `main`**. PR #2's head `05035b3` has exactly PR #3's final tree (`ea95413`), so PR #2 now carries Phase 1 and Phase 2. |
| Phase 1 and Phase 2 in `main` | **Missing, both.** `git merge-base --is-ancestor` fails for both branch heads against `origin/main`. |
| Integration PR | PR #2 already is one: it is based on `main`, contains every Phase 1 and Phase 2 commit, and has no conflicts with `main` (`main` hasn't moved since PR #2 branched). A new integration PR would duplicate it. Merging it needs the owner's approval. |
| Migrations on PR #2 | 13 (`20261016000100`–`000800`, `20261017000100`–`000500`), each with a rollback in `supabase/rollback/`. |
| CI on `05035b3` | Backend: green. iOS: all 15 UI journeys passed; one StoreKit test failed on a timing race (`expireSubscription` applies asynchronously). Fixed in PR #2 by `e42e33d`; see `PROGRESS.md` for the run on that head. |
| Other open PRs | None. PR #1 and PR #3 are merged. |
| Open issues | None. |
| Failed workflow runs | 15 in history, all on superseded commits of the two feature branches (16–17 Oct), each followed by a green run on a later commit. None on a current head. |
| Review threads | None open on PR #2 or PR #3. The Codex review of PR #3's final head reported no findings. |
| Hosted Supabase | The connected Supabase account has one project, `veyora-dev`, in the "Veyora" organization. It is not Pull Up's and Phase 3 does not touch it. Pull Up has no staging or production project yet. |

### Branching

`main` doesn't have the Phase 1 and 2 work yet, so `claude/pull-up-phase-3`
starts from PR #2's head (`05035b3`). Milestone PRs are opened as drafts
against `claude/native-ios-85igsc` and retargeted to `main` once PR #2 is
merged with a merge commit (a squash merge would make every milestone PR
conflict). Nothing is merged into `main` without the owner's approval.

## Milestones and order

The owner asked for hosted Supabase, signing/TestFlight preparation and GPS
reliability first.

| # | Milestone | Needs from the owner | Separate PR |
| --- | --- | --- | --- |
| M0 | Repository audit | Approval to merge PR #2 | — |
| M1 | Hosted Supabase: staging + production config, CI deploy, two-account tests | A Supabase project for staging (and later production) and its access token in GitHub secrets | yes |
| M9 | TestFlight pipeline on GitHub Actions | Apple Developer membership, App Store Connect API key, app record | yes |
| M3 | GPS and telemetry robustness, trace replay, validation report | A real drive for battery and background checks | yes |
| M2 | Apple sign-in lifecycle against the hosted project | Sign in with Apple key in Supabase | with M1 or own |
| M4 | DMs and social against the hosted project; shared content follows owner visibility | — | yes |
| M5 | Pull Up Pro: renewals, grace, refunds, rate limit on `verify-subscription` | App Store Connect products (proposed $3.99/month, $29.99/year) | yes |
| M6 | Notifications (APNs) | APNs key, a device | yes |
| M7 | Parts finder improvements | — | yes |
| M8 | UI polish from screenshot review | — | yes |
| M10 | Security re-check against staging | Staging project | with M1 or own |
| M11 | Device acceptance plan and bug template (`DEVICE_TEST_PLAN.md`) | A device | docs PR |

Each milestone records implemented work, test evidence, CI links,
screenshots, limitations, external blockers and remaining tasks in
`PROGRESS.md`, keeping these separate: automated tests passed, simulator
tests passed, hosted backend tests passed, physical-device tests passed,
TestFlight distribution verified.
