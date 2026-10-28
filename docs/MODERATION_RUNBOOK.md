# Moderation runbook

How Pull Up keeps objectionable content out, how reports reach a person,
and what that person does with them. Written 2026-10-26 with migrations
`20261025000300`–`20261025000320` and the `moderation-worker` function.

> **Nobody monitors reports yet.** Reports are queued and kept from the
> moment these migrations are applied. They reach a person only after the
> owner does the setup in §2: names a moderator, sets
> `MODERATION_WEBHOOK_URL`, schedules the worker, and confirms that a test
> report arrived. Until all of that is done, nothing in the app, the store
> listing or a reply to App Review may say that reports are reviewed within
> any time.

The published rules are `docs/public/community.md`. The support page is
`docs/public/support.md`. §9 maps each rule to how it's enforced.

## 1. What the server does on its own

Everything here runs in Postgres, so a direct REST or RPC request gets the
same treatment as the app. pgTAP files `030`–`034` act as ordinary,
blocked and suspended users to prove it.

| Safeguard | How | When it fails |
| --- | --- | --- |
| Text filter | Triggers on every user text column: handle and display name, bio, vehicle make, model, trim, nickname and description, mod title, brand and notes, post captions, comments, meet title, details, venue and address, messages, and drive titles. Each folds the text (case, accents, digits used as letters such as `k1ll`, symbols inside words, spaced-out letters, stretched letters), then checks it against `private.moderation_terms`. A match fails with SQLSTATE `PUM01` and a sentence the app shows as-is. A blocked handle reads as "reserved". A display name from Sign in with Apple, or a drive title the app generated, is cleared, so the sign-up or upload still goes through. | There's no external filtering service, so nothing outside Postgres can fail. The check runs inside the same transaction as the write: if the term table can't be read, the write fails as well (fail closed). **With an empty term list, nothing is blocked.** §2.2 loads the list. |
| Photos and videos | No automated screening (§8). Reports, removal, and auto-hide after reports from 3 different accounts. | — |
| Auto-hide | When 3 different reporters with accounts older than a day have open reports on the same post, comment, meet or vehicle, it's hidden as `pending_review` until a moderator decides. Its reports become urgent. | — |
| Reports | `report_user` and `report_content` (post, comment, meet, profile, vehicle, message) keep a snapshot of the reported content (text, photo and video paths, mods). The snapshot stays after the content or either account is deleted. | — |
| Blocks | Blocking cuts all reads and writes between the two accounts: profiles, posts, comments, likes, follows, meets and RSVPs (including changing an RSVP made before the block), messages and reactions, and shared cards. The app hides the blocked person everywhere straight away. | — |
| Suspension | `private.account_suspensions`. Every write path refuses the suspended account's own writes (`PUM02`, with the reason): profile, bio, vehicles, mods, photos, uploads to any bucket, posts, likes, comments, meets, RSVPs, follows, conversations, messages and reactions. The person can still read, sign out, delete their own content, cancel their own meets, change settings and who can see their things, report, block, and delete their account. The app shows a banner. | — |
| Removal | `moderation_state` on posts, comments, meets, vehicles and messages. Removed content disappears from every read path (tables, feed, comment counts, inbox previews, shared cards, storage reads) for everyone except moderators. Its owner sees it marked as removed. Media is deleted from Storage after the evidence hold (§6). | — |
| Rate limits | §7 | — |

## 2. One-time setup (owner)

Do this separately for staging and production. Nothing here costs money.

### 2.1 Name a moderator

Moderator rights are a row in `private.moderators`. No API role can write
it, the service role included. Only the project owner can, in the SQL
editor. Each change is written to the audit log.

```sql
-- the moderator's Pull Up account id (Authentication ▸ Users)
insert into private.moderators (user_id, note) values ('<uuid>', 'Owner, primary moderator');
```

Remove a moderator with `delete from private.moderators where user_id = '<uuid>';`.

### 2.2 Load the term list

1. Read `supabase/moderation/starter_terms.sql`. It holds threat and
   self-harm phrases only. Run it in the SQL editor.
2. Add slurs and sexual terms from a list you've vetted yourself, in the SQL
   editor. Don't commit that list: the repository is public.
   `select public.mod_add_term('<term>', 'word', 'slur', '<note>');`
   Use `'contains'` only for strings that never appear inside ordinary
   words, because it matches anywhere in the text.
3. Test texts with `select public.mod_check_text('...');`, which returns
   the matching term or null. Test some ordinary car talk as well
   ("Scunthorpe", "assembly", "cocktail", "classic").
4. Remove a term with `select public.mod_remove_term('<term>');`.

Existing content is not re-checked when a term is added. Only new writes,
and edits to the changed column, are checked.

### 2.3 Choose where alerts go

`MODERATION_WEBHOOK_URL` must be an `https` URL that accepts a JSON POST.
These options are free:

* A Discord channel webhook: Channel ▸ Integrations ▸ Webhooks. The
  payload's `content` field is what Discord shows.
* A Slack incoming webhook (uses the `text` field).
* An ntfy.sh topic with a long, random name, read in the ntfy app. Anyone
  who knows the topic can read it, but messages carry no names or content
  (below).
* Your own endpoint. Set `MODERATION_WEBHOOK_SECRET` as well and check
  `x-pullup-signature: sha256=<hex HMAC-SHA256 of the body>`.

Each message lists report ids, reasons, kinds, priorities and queue counts.
It never includes the reported text, media, names or account ids.

Add `MODERATION_WEBHOOK_URL` (and optionally `MODERATION_WEBHOOK_SECRET`)
to the GitHub environment (`SUPABASE_SETUP.md` §3), next to `CRON_SECRET`.
The next Supabase deploy run with apply ticked copies them to the
project's function secrets. Don't set them with `supabase secrets set`: a
deploy removes any function secret that isn't in the environment.

### 2.4 Schedule the worker

The worker uses the same Cron, `pg_net` and Vault setup as `dm-retention`
(`SUPABASE_SETUP.md` §5). It needs two jobs:

```sql
select cron.schedule('pullup-moderation', '*/5 * * * *', $$
  select net.http_post(
    url := 'https://<ref>.supabase.co/functions/v1/moderation-worker',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer <anon key>',
      'x-pullup-cron-secret', (select decrypted_secret
        from vault.decrypted_secrets where name = 'pullup_cron_secret')),
    body := '{}'::jsonb);
$$);

select cron.schedule('pullup-moderation-digest', '0 14 * * *', $$
  select net.http_post(
    url := 'https://<ref>.supabase.co/functions/v1/moderation-worker',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer <anon key>',
      'x-pullup-cron-secret', (select decrypted_secret
        from vault.decrypted_secrets where name = 'pullup_cron_secret')),
    body := '{"digest": true}'::jsonb);
$$);
```

Each run deletes due media, applies retention, then sends undelivered
reports in batches of up to 20. A failed send is retried after 2, 4, 8 …
minutes, at most 6 hours apart. After 12 failed attempts it's marked
`failed`, and the queue and digest show it. The function answers **503**
while `MODERATION_WEBHOOK_URL` is missing, so the cron history
(`select * from net._http_response order by created desc limit 5;`) shows
it isn't configured. The digest is sent only when something is open or has
failed.

### 2.5 Test delivery, then start monitoring

0. Before any account exists, check the alert route alone. In the SQL
   editor:

   ```sql
   select net.http_post(
     url := 'https://<ref>.supabase.co/functions/v1/moderation-worker',
     headers := jsonb_build_object(
       'Content-Type', 'application/json',
       'Authorization', 'Bearer ' || (select decrypted_secret
         from vault.decrypted_secrets where name = 'pullup_anon_key'),
       'x-pullup-cron-secret', (select decrypted_secret
         from vault.decrypted_secrets where name = 'pullup_cron_secret')),
     body := '{"test": true}'::jsonb);
   ```

   A message reading "Pull Up moderation (production): test alert…" should
   appear in the channel, and
   `select status_code, content from net._http_response order by created desc limit 1;`
   should read 200 with `"test_sent":true`. It carries no report data. This
   proves only the route; steps 1–4 still have to pass.
1. From a second test account, report a post.
2. Within 5 minutes the alert should arrive. Check
   `select status, attempts, last_error from private.moderation_deliveries order by created_at desc limit 3;`
   It should read `delivered`.
3. Work through that report using §3, then dismiss it.
4. Write down who monitors, which channel they watch, and the response
   times you'll commit to (§5). Only then can reports be described as
   monitored. If the moderator changes, repeat this test.

## 3. Triage (moderator)

Moderators work in the SQL editor while signed in as the project owner,
or call the same RPCs from their own moderator account. Every action is
written to `private.moderation_audit`, which can't be edited or deleted
(only `moderation_purge` removes rows, after 2 years).

1. **Open the queue:** `select * from public.mod_queue();` Urgent reports
   come first, then the oldest. `reports_on_content` and
   `subject_reports_actioned` show patterns. `delivery_status` shows
   whether the alert went out. Pass `'all'`, `'actioned'` or
   `'dismissed'` to see others.
2. **Read one report:** `select public.mod_report('<report id>');` This
   returns the report with its snapshot, the content as it is now, the
   subject's other reports, any suspension, and the audit trail. To view
   media from the snapshot, open the path in Storage. Removed media stays
   there until the hold ends.
3. **Mark it as being looked at** (optional):
   `select public.mod_resolve_report('<id>', 'reviewing', 'note');`
4. **Decide:**

   | Finding | Action |
   | --- | --- |
   | No violation | `select public.mod_resolve_report('<id>', 'dismissed', 'why');` If the content was auto-hidden, restore it with `mod_set_content_state('<kind>', '<content id>', 'visible', '<id>', 'why')`. |
   | One item breaks the rules | `select public.mod_set_content_state('<kind>', '<content id>', 'removed', '<id>', 'why');` `kind` is `post`, `comment`, `meet`, `vehicle` or `message`. Every open report about that item becomes `actioned`. |
   | Profile (handle, name, bio, avatar) | `select public.mod_reset_profile('<user>', array['bio','avatar'], '<id>', 'why');` Fields: `display_name`, `bio`, `avatar`, `username` (resets to a placeholder `driver_…`; the app has no handle change after onboarding, so the person keeps it unless support changes it). |
   | Repeated or serious abuse | `select public.mod_suspend_user('<user>', now() + interval '7 days', 'Reason shown to the person', '<id>', false);` Pass `null` as the date for an indefinite suspension, and `true` as the last argument to also remove all of their posts, comments, meets and vehicles. |
   | Lift a suspension | `select public.mod_unsuspend_user('<user>', 'why');` |
   | Pause messaging only | SQL editor: `insert into private.messaging_pauses (user_id, paused_until, note) values ('<user>', now() + interval '7 days', 'why') on conflict (user_id) do update set paused_until = excluded.paused_until, note = excluded.note;` Lift with `delete from private.messaging_pauses where user_id = '<user>';`. Only the person (`my_moderation_status`) and moderators (`mod_report`) can see a pause. |

   Write the reason for a suspension as a sentence you'd say to the
   person: the app shows it to them word for word.
5. **Check the summary:** `select public.moderation_summary();`
   `open_over_24h` should be 0.

## 4. Escalation

* **Urgent:** reports with reason `violence` or `sexual`, and anything
  auto-hidden. Handle these first.
* **Immediate danger to someone:** contact local emergency services. Pull
  Up has no emergency function, and the community page says so.
* **Sexual content involving a minor:** remove it at once with
  `mod_set_content_state(..., 'removed', ..., p_media_hold => interval '90 days')`
  so the evidence stays. Suspend the account, don't download or forward the
  media, and get legal advice on reporting obligations (in the US, to
  NCMEC). This is an owner and legal decision. This runbook doesn't make it.
* **Legal requests and copyright notices:** the owner handles these. Keep
  the content removed but not purged (longer media hold) until it's
  resolved.
* **Appeals:** the person contacts support (`docs/public/support.md`).
  The moderator reviews `mod_report` and the audit log and restores
  (`'visible'`) or lifts the suspension. Note the outcome in the call.

## 5. Response times (owner decision)

Proposed targets, not yet agreed: **urgent within 24 hours, others within
72 hours**. App Review generally expects reports to be handled in a timely
way. Pick numbers you can keep, write them in §2.5 step 4, and only then
mention them anywhere public.

## 6. Evidence and retention

| Data | Kept | Removed by |
| --- | --- | --- |
| Report and snapshot | Open reports: until a moderator closes them. Closed: 1 year | `dm_purge` (`dm-retention` cron). Only runs if that job is scheduled |
| Report's reporter and subject ids | Cleared (set null) when that account is deleted. The snapshot stays | FK `on delete set null` |
| Removed content (row) | Stays hidden while its owner keeps it. Deleted with the account, or when the owner deletes it | Owner or account deletion |
| Media of removed content | Default hold 30 days (`p_media_hold`), then deleted from Storage | `moderation-worker`, only if scheduled |
| Audit log | 2 years | `moderation_purge` (worker) |
| Delivery records | 90 days after the report closes | `moderation_purge` |
| Suspension records | 2 years after they end | `moderation_purge` |

Snapshots can hold text and media paths of people who later delete their
accounts. The privacy policy and the delete-account screen should say that
report records are kept for safety. That's an owner and privacy-track
item: the current pages say retention for reports is "explained in the
privacy policy".

## 7. Rate limits

Per account, counting attempts (deleting doesn't give a slot back). Server
writes (SQL editor, service role) aren't limited. Exceeding one returns
`54000` "You're doing that a lot. Wait a few minutes and try again."

| Write | Per minute | Per hour |
| --- | --- | --- |
| Posts | 5 | 30 |
| Comments | 10 | 100 |
| Messages | 60 | 600 (plus the existing caps on requests) |
| Reactions | 60 | 500 |
| Likes | 60 | 500 |
| Follows | 30 | 200 |
| Meets | 3 | 10 |
| RSVPs | 20 | 100 |
| Vehicles | 5 | 20 |
| Mods / vehicle photos | 30 | 200 |
| Reports | 5 | 15 (and 20 a day) |

## 8. Automated media screening (owner decision)

No automated image or video screening runs, because every option is an
external service with cost or data-sharing terms the owner hasn't approved.
Options, if wanted later:

* Apple's on-device `SensitiveContentAnalysis` framework. It's free and
  needs no server, but it only works when the user has turned on Sensitive
  Content Warnings, so it can't be enforced.
* A hosted classifier such as AWS Rekognition, Google Cloud Vision
  SafeSearch, Hive or Sightengine. These are paid per image and need a
  processor agreement and a privacy-policy update. They would run from an
  edge function on upload and set `moderation_state = 'pending_review'` on
  a hit.
* Hash matching for known abuse imagery (PhotoDNA, via an application to
  Microsoft or NCMEC).

Until then, media relies on reports, auto-hide and removal.

## 9. Community rules and how they're enforced

| `docs/public/community.md` | Enforcement |
| --- | --- |
| Keep driving safe | Reports (reason `dangerous_driving`) → removal. Leaderboards don't offer speed metrics (Swift test `leaderboardsNeverOfferSpeed`) |
| Respect other people: threats, harassment | Term list (threats), reports, block, removal, suspension |
| Keep content appropriate | Term list (owner-loaded), reports, auto-hide, removal |
| Share only what you may share | Reports, removal. Copyright notices go to the owner (§4) |
| Spam | Rate limits, term list (`spam` category), reports |
| Don't evade a block or suspension | Server enforcement on every path. Evasion with a new account is handled by suspending that account too. There's no device or identity link |

Suggested additions to `docs/public/community.md`, for whoever owns that
page: vehicles can be reported from their page; a suspended account can
still read, sign out and delete itself; contact support to appeal. Add
response times only after §5 is decided.

## 10. Age rating

These answers are based on Apple's "Age ratings values and definitions"
page as it stood on 2026-10-23. Recheck them in App Store Connect, since
the questionnaire decides the rating, and a rating doesn't prove the app
meets any law.

* User-Generated Content: **Yes**. Messaging and Chat: **Yes**. Social
  Media: **Yes**. With Social Media at Yes, the expected rating is **13+**
  in most regions.
* Regional ratings Apple derives from the same answers include:
  Australia 16+ (social media), Brazil A16 (social media), Korea 15+,
  Vietnam 16+. **Which regions to launch in is an owner decision.** Some of
  these come with local obligations, such as Australia's minimum age for
  social media, that a store rating doesn't satisfy. Get advice before
  choosing those regions.
* Contests: the earlier draft answered **No** because leaderboards carry
  no prizes. Leaderboards do rank people, though, so decide whether that's
  "infrequent" or "frequent" contests (13+ if frequent) and answer to match.
* Pull Up has no minimum-age check or age assurance. The terms and
  minimum-age track (migrations `20261025000400`–`499`) owns that. Don't
  answer "Age Assurance: Yes" or "Social Media Disabled for Users Under
  13: Yes" until that work ships.

## 11. Known gaps

* Unblock: the server allows it (`blocks` delete policy), but the app has
  no unblock or blocked-accounts list.
* A report about a person from a conversation, without a specific
  message, has no content kind. Act on the account (`mod_reset_profile`,
  `mod_suspend_user`). A reported message has kind `message` and can be
  removed like other content.
* Existing content isn't rescanned when terms are added.
* A suspended user can make a new account (§9).
* Moderators use SQL or RPCs. There's no moderator screen in the app.
