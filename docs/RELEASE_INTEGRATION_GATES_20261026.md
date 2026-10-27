# Pull Up release integration gates — October 26, 2026

> Snapshot / audit handoff, **not a certificate of compliance**. Inspected GitHub `main` commit `2addf202667e1c06a08158a1dce8d1929bac6e14` and the five open draft PR descriptions plus selected code and documentation. PR authors' local/CI test claims are recorded as claims unless independently verified. No native code was compiled here, no device was used, and no hosted Pull Up project was accessible from the connected Supabase account.

## Scope and statuses

Use exactly these states for a **requirement-to-evidence** record:
- **Verified**: suitable traceable evidence has been inspected for that requirement.
- **Implemented, verification pending**: implementation exists but an applicable end-to-end check is missing.
- **Blocked**: missing deployment, approval, system access or operational setup prevents satisfaction.
- **Not applicable**: excluded from the intentionally deferred release scope, with a reason.

These states are a point-in-time snapshot; rerun the matrix against the **merged** release-candidate commit and actual deployed binary before claiming readiness.

| Requirement | Official source / section | Surface / proposed implementation | Verification and evidence | Status | Owner action / gate |
| --- | --- | --- | --- | --- | --- |
| Re-audit source version | Internal source control | `main` / native `project.yml` | Confirmed `main` SHA `2addf202`; `MARKETING_VERSION: 0.1.0` | Verified | Pin a new SHA after approved merges |
| Consistent 1.0 metadata, signing, entitlements | App Review 2.1, 2.3 | Draft [#29](https://github.com/AaravJit/pull-up/pull/29), `native/ios/scripts/release-provenance.sh` | PR describes guards but no candidate signed IPA evidence | Blocked | Approve reviewed fixes; signed build, inspect provenance and App Store Connect processing |
| User account deletion and Apple revocation | App Review 5.1.1(v) | Draft [#31](https://github.com/AaravJit/pull-up/pull/31), `delete-account`, storage cleanup | PR reports paginated/retry tests; not on hosted production | Blocked | Review migration+app together; staging and Apple revocation tests |
| Complete uploads and duplicate resistance | App Review 2.1 / data integrity | Draft [#33](https://github.com/AaravJit/pull-up/pull/33), `publish_post` RPC, `PostPublisher`, cleanup function | Claimed local/CI coverage; no hosted, old-client compatibility and media cleanup proof | Blocked | Deploy alongside app update, run real Storage/API tests; schedule cleanup |
| UGC filtering before publish | App Review 1.2 | Draft [#32](https://github.com/AaravJit/pull-up/pull/32) server trigger + moderation terms | **Term list initialized empty; blocks nothing until populated.** Image/video screening not established | Blocked | Approve appropriate terms, media safeguards or manual hold process, prove direct API enforcement |
| Respond to reports and block abusive users | App Review 1.2 | Draft #32, queue, audited enforcement, worker | No established moderator, contact, webhook receiver, scheduled execution or measured response | Blocked | Name operator, create tested alert path and response SLA; exercise block/report/removal |
| Privacy disclosures match observed collection | App Review 5.1.1 and App Privacy | Draft [#34](https://github.com/AaravJit/pull-up/pull/34), inventory, `PrivacyInfo.xcprivacy`, public policy | PR relies on #31–#33 before merging; no archived privacy report / App Store Connect reconciliation | Blocked | Verify merged binary+backend, then publish accurate privacy answers and policy |
| Cross-account authorization, RLS, storage | App Review 1.6, 5.1 | Supabase schema and `two_accounts_test.ts` | Older staging tests in `docs/STAGING_DEPLOYMENT.md`; changes from #31–#33 not tested on hosted project | Blocked | Allow controlled synthetic staging accounts; run two-account tests after approved migration deployment |
| Real recording and recovery | App Review 2.1, 5.1.5 | Drive recorder, local persistence, location prompts | `docs/PROGRESS.md` reports no completed physical-device run | Blocked | Real iPhone tests: denial, reduced accuracy, lock/background, GPS loss, offline/resume, cleanup |
| Screen/layout/accessibility | HIG; App Store accessibility criteria | Native SwiftUI screens, #29 picker correction | Simulator CI cannot establish large type/VoiceOver or actual Duo hardware behavior | Implemented, verification pending | Device and simulator matrix with readable content, focus, contrast and motion evidence |
| Authentic, candidate-linked screenshots | App Review 2.3.3; screenshot specifications | CI screenshot captures and real simulator renders | No final version/build/export hashes demonstrated for submission | Blocked | Capture after code freeze from same RC build, check file sizes, image hashes, accurate claims |
| iPhone Duo screenshots *today* | App Store screenshot specifications | Outer and inner displays | Apple states screenshots for iOS 27.1 SDK+ required starting **April 2027** | Not applicable | Not yet mandatory as of this snapshot; voluntarily test layouts and prepare authentic captures |
| Public contact and functional links | App Review 1.2, 5.1.1 | Draft #29 pages / #32 runbook | Owner-approved public support contact not established | Blocked | Supply a real public support address and test external links in signed app |
| Age rating, markets, review account and metadata | App Review 2.3; App Store Connect | App Store record | Owner decisions and concrete reviewer login unverified | Blocked | Select age/markets honestly, create reviewer account, complete metadata and review notes |
| Sign in with Apple and APNs | App Review 4.8 where applicable; 2.1 | Native auth / Supabase Apple / notifications | Dashboard settings described, no physical-device Apple sign-in or push evidence | Blocked | Configure both hosted environments; device sign-in and APNs test |
| Pro subscription launch | App Review 3.1 | `PULLUP_PRO_OFFERED = NO` on main | Intentionally deferred and hidden for non-entitled accounts | Not applicable | Keep hidden; reevaluate only when approved as new scope |
| CarPlay entitlement | App Review 2.5 | Not in release entitlement path; draft #29 removes residual CarPlay scene | Intentionally deferred | Not applicable | Do not advertise until entitled and hardware-tested |
| eBay in-app marketplace, prices, fitment | App Review 2.3 | External search link only | In-app integration is explicitly not launch scope | Not applicable | Copy must say external search, not live in-app marketplace |

## Critical integration dependencies

1. **Do not interpret open draft PRs as mainline features.** The migration PRs are independent branches with overlapping `SupabaseBackend.swift`, `AppModel.swift`, `docs/SUPABASE_SETUP.md`, `supabase/applied/staging.sha256`, and other files. Verify the combined diff, conflict resolutions, and complete tests **after** approved merges. In particular, #34 explicitly requires #31, #32 and #33.
2. **Do not apply migrations independently of the release app.** #33 revokes direct `post_media` insertion and expects new `publish_post` client behavior. Existing installed builds could leave text-only posts after a backend-first migration. Require a documented compatible rollout / upgrade gate.
3. **Account deletion must not leave revoked-but-live Apple accounts.** #31 changes ordering and retry semantics. Verify >1,000 objects, nested paths, partial failures and replay on the real hosted API and a physical device.
4. **A moderation trigger with an empty dictionary is not a functional content filter.** Terms, media response, a staffed response path and public support are separate operational gates. Do not claim someone is watching reports until an actual person and on-call process exist.
5. **Supabase access mismatch.** The connected Supabase account enumerated only organization `Pathway` (Free) and an inactive project; it did not reveal the separately described Pull Up Pro organization and `pull-up-staging`. Do not deploy or provision against the wrong organization; reauthorize the correct one.
6. **Don't confuse CI checks and the signed App Store candidate.** Previous documentation shows signed 0.1.0 (233) upload accepted, not App Store Connect processing/installation. Produce SHA-256 and source provenance for the final signed 1.0 IPA before review.

## Official sources checked on October 26, 2026

- [Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) — displayed last updated **October 16, 2026**; relevant §§ 1.2, 2.1, 2.3, 3.1, 5.1.1, 5.1.5.
- [Apple account deletion guidance](https://developer.apple.com/help/app-review/guideline-reference/5-1-1-account-deletion/).
- [Apple App Privacy](https://developer.apple.com/app-store/app-privacy-details/).
- [Apple screenshot dimensions](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications) and [screenshot authenticity](https://developer.apple.com/help/app-review/guideline-reference/2-3-3-screenshots).
- [Apple complete review information](https://developer.apple.com/help/app-review/before-submitting-for-review/complete-review).
- [Apple Developer Program License Agreement](https://developer.apple.com/support/terms/apple-developer-program-license-agreement/) — owner must verify the terms actually accepted inside their developer account. The exact historically effective Oct 24 license revision was not proven from the public page.

## Verdict

**NOT READY —** release-critical PRs are not integrated; live Pull Up backend access and configured production project are not established in this connection; moderation operations, privacy labels, signed 1.0 build, physical-device behavior and candidate screenshots lack sufficient end-to-end evidence. No migration, purchase, merge or App Review submission is authorized by this report.
