# SECURITY DEFINER functions signed-in users can call

The Supabase security advisor (lint 0029, "Signed-In Users Can Execute SECURITY DEFINER Function") lists every `public` function that runs as its owner and that the `authenticated` role can call through `/rest/v1/rpc/...`. A warning is not a vulnerability in itself. Each function must have a reason to bypass row level security and must limit itself to what the caller may see or change. This file gives both for every function.

- **Advisor on staging** (2026-10-27): 38 such functions.
- **Combined schema of main plus #31, #32 and #33:** 53. The 15 added since are the moderator calls, `publish_post` and `my_moderation_status`.
- **With #37 (consent and minimum age) as well:** 56. It adds `my_consent_ok`, `my_consent_status` and `record_age_check`, all limited to the caller.

**Checked everywhere.** Every function:
- pins `search_path = ''`, checked by `006_security_surface.sql`;
- cannot be called by anon, also checked by 006;
- takes the caller only from `auth.uid()`, never from an argument.

**Tests.**
- `020_definer_review.sql` pins the reviewed list. A new definer function fails CI until it is added here and to that list.
- 020 also calls every function no other test calls, using a stranger's ids.

## Why definer at all

- **Visibility helpers** (`can_view*`, `is_friend`, `is_blocked_between`, `is_attending`):
  - They are used inside RLS policies, where they have to read other people's rows (blocks, follows, privacy settings) that the caller's own RLS would hide.
  - Running as invoker would recurse into the same policies.
  - Each returns only a boolean about the caller, or about content the caller asks to see.
- **Counts on a row** (`like_count`, `comment_count`, `going_count`, `interested_count`):
  - These are PostgREST computed columns. They count rows the caller can't read one by one.
  - Each returns 0 unless the caller can see the post or meet. This was finding G-counts, tested in 012.
- **Write paths** that touch more than the caller's rows (`start_conversation`, `publish_post`, `report_*`, `respond_to_request`, `share_drive_route`):
  - They need to insert into tables with no direct insert grant, or to check another person's settings.
  - Each starts by refusing a null `auth.uid()` or a resource the caller doesn't own.
- **Moderator calls** (`mod_*`, `moderation_summary`): each calls `private.moderation_actor()` first.
  - That function raises 42501 unless `auth.uid()` is listed in `private.moderators`.
  - Only the project owner can write `private.moderators`, from the SQL editor.

## Function by function

"Own only" means the function filters on `auth.uid()`, so another person's ids match nothing.

| Function | What limits it | Tested in |
|---|---|---|
| attach_drive_to_track_event | Own drive, verified organiser, own going RSVP, time window, start within 3 km. Speed boards are closed anyway (20261024000100). | 020 |
| begin_identity_link | Signed in; writes an intent for the caller only | 002 |
| can_view | Owner, block, profile visibility and friendship, all for the caller | 020, 001 |
| can_view_drive / _meet / _post / _vehicle | `can_view` plus moderation state | 009, 020, 001 (via policies) |
| claim_username | Own profile; name checked by `username_problem` and the moderation filter | 002, 030 |
| comment_count, like_count, going_count, interested_count | 0 unless the caller can see the post or meet | 012 |
| complete_onboarding | Own profile | 002 |
| drive_history_ceiling | Real setting only for the owner; `private` for anyone else | 009, 020 |
| get_profile | Null for blocked users; bio and region only when content is visible. Username, name and avatar of a private profile are visible by design (disclosed). | 015, 033 |
| hide_conversation, set_conversation_muted, mark_conversation_read | Own membership row only | 020, 003 |
| inbox, unread_message_counts | Own memberships; blocked peers skipped | 003, 033, 020 |
| is_attending, liked_by_me, my_rsvp, owns_vehicle | Own only | 020 |
| is_blocked_between, is_friend | False unless the caller is one of the two people | 006 |
| leaderboard | Signed in; opted-in, non-private, non-blocked people only; performance boards empty (constraint in 20261024000100) | 001, 009, 014 |
| meet_attendees | Visible meet; others shown only with `show_me` and only to attendees; blocked skipped | 001, 033 |
| mod_* (11), moderation_summary | `moderation_actor()`: moderators only | 031, 032, 020 |
| my_consent_ok | Answers for the caller only (`auth.uid()`); used by storage policies | 040, 041 |
| my_consent_status | Caller's own terms acceptance and age check only | 040, 041 |
| my_moderation_status | Own suspension only | 032 |
| peer_read_at | Members only (`peer_of` checks the caller), active chats, both opted in to receipts | 003, 020 |
| publish_post | Signed in; author forced to the caller; files must be in the caller's folder for that post id; table triggers still run (filter, rate limit, suspension) | 019 |
| record_age_check | Writes the caller's own age answer only. One-way: a recorded "under the minimum" can't be flipped to "meets" (PUC02); an under-minimum answer makes the caller's own profile private and closes messages | 041 |
| register_device_token | Signed in; token format checked; at most 10 per account. See finding D1. | 005 |
| report_content, report_user | Signed in; only content the caller can see; not yourself; 5/15 min and 20/day | 016, 031, 034 |
| respond_to_request | Own request row, else 42501 | 020 |
| share_drive_route, unshare_drive_route | Own drive; sharing must be on | 001, 012, 020 |
| shared_preview | `can_view_shared`; otherwise "unavailable" | 003, 032, 033 |
| start_conversation | Not self, not blocked, recipient's `messages_from`, 20 a day, suspension | 003, 006, 033 |
| unsend_message | Own message only | 003, 020 |
| username_status | Signed in; answers available or the problem | 002 |

## Findings from this review

- **D1 (low): `register_device_token` reassigns an existing token to the caller.**
  - This is intended: a phone that changes accounts keeps one token.
  - Someone who learned another device's APNs token could move it to their own account and send their own notifications to that phone. Tokens are 32-byte values that leave the phone only for Pull Up's server, so this needs the token first.
  - Not fixed; noted here.
- **S2 (low to medium): `profiles.messaging_suspended_until` is readable by any signed-in user.**
  - `start_conversation` reads it. The column itself is selectable on `profiles`, which leaks whether someone has a messaging pause.
  - Owner: the moderation PR (#32).

## Keeping this current

When a migration adds or changes a definer function that `authenticated` can execute:
1. Add a row above.
2. Add the name to the list in `020_definer_review.sql`.
3. Make sure some test calls it with another person's ids.

Re-run the advisor (Supabase connector `get_advisors`, security) after each deploy and compare its list with this file.
