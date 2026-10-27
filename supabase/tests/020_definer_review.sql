-- Every SECURITY DEFINER function a signed-in user can call through the API
-- (the Supabase advisor's lint 0029) has been reviewed: docs/security/DEFINER_FUNCTIONS.md
-- says why each one runs as definer and how it limits itself to what the
-- caller may see or change. This file pins that list, so a new definer
-- function fails here until it is reviewed, and probes the functions no
-- other test calls with a stranger's ids.

begin;
create extension if not exists pgtap with schema extensions;
select plan(22);

create or replace function pg_temp.act_as(uid uuid) returns void language plpgsql as $$
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', uid::text, true);
end $$;

create or replace function pg_temp.as_admin() returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
end $$;

-- 1: only reviewed definer functions are callable by signed-in users -------
select is(
  (select coalesce(array_agg(p.proname::text order by p.proname), '{}')
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prosecdef and p.prorettype <> 'trigger'::regtype
      and has_function_privilege('authenticated', p.oid, 'execute')
      and p.proname <> all (array[
    'attach_drive_to_track_event', 'begin_identity_link', 'can_view', 'can_view_drive', 'can_view_meet',
    'can_view_post', 'can_view_vehicle', 'claim_username', 'comment_count', 'complete_onboarding',
    'drive_history_ceiling', 'get_profile', 'going_count', 'hide_conversation', 'inbox',
    'interested_count', 'is_attending', 'is_blocked_between', 'is_friend', 'leaderboard',
    'like_count', 'liked_by_me', 'mark_conversation_read', 'meet_attendees', 'mod_add_term',
    'mod_check_text', 'mod_queue', 'mod_remove_term', 'mod_report', 'mod_reset_profile',
    'mod_resolve_report', 'mod_set_content_state', 'mod_suspend_user', 'mod_terms', 'mod_unsuspend_user',
    'moderation_summary', 'my_moderation_status', 'my_rsvp', 'owns_vehicle', 'peer_read_at',
    'publish_post', 'register_device_token', 'report_content', 'report_user', 'respond_to_request',
    'set_conversation_muted', 'share_drive_route', 'shared_preview', 'start_conversation', 'unread_message_counts',
    'unsend_message', 'unshare_drive_route', 'username_status'
    ]::text[])),
  '{}'::text[], 'every definer function signed-in users can call is in the reviewed list');

-- Ann owns a drive, a vehicle, a liked post and a meet she is going to, and
-- has a conversation with Cat. Ben is a stranger to both.
insert into auth.users (id, email, raw_user_meta_data) values
  ('ed000000-0000-0000-0000-00000000000a', 'def-ann@example.com', '{"username":"def_ann"}'),
  ('ed000000-0000-0000-0000-00000000000b', 'def-ben@example.com', '{"username":"def_ben"}'),
  ('ed000000-0000-0000-0000-00000000000c', 'def-cat@example.com', '{"username":"def_cat"}');

select pg_temp.act_as('ed000000-0000-0000-0000-00000000000a');
update public.privacy_settings set allow_route_sharing = true where user_id = auth.uid();
insert into public.vehicles (id, owner_id, kind, make, model, year, visibility)
values ('ed100000-0000-0000-0000-000000000001', auth.uid(), 'car', 'Mazda', 'MX-5', 2019, 'public');
insert into public.drives (id, owner_id, started_at, ended_at, distance_m, moving_s, stopped_s, elapsed_s, top_speed_mps, visibility)
values ('ed200000-0000-0000-0000-000000000001', auth.uid(), now() - interval '2 hours', now() - interval '1 hour',
        20000, 3000, 600, 3600, 25, 'private');
insert into public.posts (id, author_id, kind, visibility, caption)
values ('ed300000-0000-0000-0000-000000000001', auth.uid(), 'moment', 'public', 'Sunday run');
insert into public.likes (post_id, user_id) values ('ed300000-0000-0000-0000-000000000001', auth.uid());
insert into public.meets (id, host_id, title, kind, starts_at, ends_at, venue_name, lat, lon, visibility)
values ('ed400000-0000-0000-0000-000000000001', 'ed000000-0000-0000-0000-00000000000a', 'Coffee meet', 'meet',
        now() + interval '1 day', now() + interval '1 day 2 hours', 'Lot', 38.57, -121.48, 'public');
insert into public.meet_rsvps (meet_id, user_id, status, show_me)
values ('ed400000-0000-0000-0000-000000000001', auth.uid(), 'going', true);

create temporary table ids (k text primary key, v uuid) on commit drop;
grant all on ids to authenticated;
insert into ids values ('conv', public.start_conversation('ed000000-0000-0000-0000-00000000000c'));
insert into public.messages (id, conversation_id, sender_id, body)
values ('ed500000-0000-0000-0000-000000000001', (select v from ids where k = 'conv'), auth.uid(), 'See you there');
select pg_temp.as_admin();
update public.conversation_members set last_read_at = now() - interval '1 day'
 where conversation_id = (select v from ids where k = 'conv');

-- 2-19: Ben calls each with Ann's and Cat's ids ----------------------------
select pg_temp.act_as('ed000000-0000-0000-0000-00000000000b');

select throws_ok($$ select public.attach_drive_to_track_event('ed200000-0000-0000-0000-000000000001', 'ed400000-0000-0000-0000-000000000001') $$,
  '42501', null, 'attach_drive_to_track_event refuses someone else''s drive');
select ok(not public.can_view('ed000000-0000-0000-0000-00000000000a', 'private'),
  'can_view: a stranger can''t see what Ann keeps private');
select ok(not public.can_view('ed000000-0000-0000-0000-00000000000a', 'friends'),
  'can_view: a stranger isn''t Ann''s friend');
select ok(not public.can_view_drive('ed200000-0000-0000-0000-000000000001'),
  'can_view_drive: a stranger can''t see Ann''s private drive');
select ok(not public.is_attending('ed400000-0000-0000-0000-000000000001'),
  'is_attending answers for the caller only');
select ok(not public.liked_by_me(jsonb_populate_record(null::public.posts, '{"id":"ed300000-0000-0000-0000-000000000001"}')),
  'liked_by_me reports the caller''s likes, not the author''s');
select is(public.my_rsvp(jsonb_populate_record(null::public.meets, '{"id":"ed400000-0000-0000-0000-000000000001"}')), null::jsonb,
  'my_rsvp reports the caller''s RSVP, not Ann''s');
select ok(not public.owns_vehicle('ed100000-0000-0000-0000-000000000001'),
  'owns_vehicle answers for the caller only');
select is(public.drive_history_ceiling('ed000000-0000-0000-0000-00000000000a'), 'private'::public.visibility,
  'drive_history_ceiling never reveals another person''s setting');
select is(public.peer_read_at((select v from ids where k = 'conv')), null::timestamptz,
  'peer_read_at tells a non-member nothing');
select is((select row(u.unread_conversations, u.requests)::text from public.unread_message_counts() u), '(0,0)',
  'unread_message_counts counts only the caller''s conversations');
select public.hide_conversation((select v from ids where k = 'conv'), true);
select public.set_conversation_muted((select v from ids where k = 'conv'), true);
select public.mark_conversation_read((select v from ids where k = 'conv'));
select throws_ok($$ select public.respond_to_request((select v from ids where k = 'conv'), true) $$,
  '42501', null, 'respond_to_request refuses a conversation the caller isn''t in');
select throws_ok($$ select public.unsend_message('ed500000-0000-0000-0000-000000000001') $$,
  '42501', null, 'unsend_message refuses someone else''s message');
select throws_ok($$ select public.share_drive_route('ed200000-0000-0000-0000-000000000001') $$,
  '42501', null, 'share_drive_route refuses someone else''s drive');
select throws_ok($$ select public.unshare_drive_route('ed200000-0000-0000-0000-000000000001') $$,
  '42501', null, 'unshare_drive_route refuses someone else''s drive');
select throws_ok($$ select public.mod_terms() $$, '42501', null, 'mod_terms is for moderators only');
select throws_ok($$ select public.mod_remove_term('anything') $$, '42501', null, 'mod_remove_term is for moderators only');
select throws_ok($$ select public.mod_reset_profile('ed000000-0000-0000-0000-00000000000a', array['bio']) $$,
  '42501', null, 'mod_reset_profile is for moderators only');

-- 20-22: what Ben tried changed nothing ------------------------------------
select pg_temp.as_admin();
select is((select count(*)::int from public.conversation_members
            where conversation_id = (select v from ids where k = 'conv')
              and (hidden_at is not null or muted or last_read_at > now() - interval '1 hour')), 0,
  'hide_conversation, set_conversation_muted and mark_conversation_read changed nothing for Ann or Cat');
select is((select count(*)::int from public.conversation_members
            where conversation_id = (select v from ids where k = 'conv')
              and user_id = 'ed000000-0000-0000-0000-00000000000b'), 0,
  'and didn''t add Ben to the conversation');
select pg_temp.act_as('ed000000-0000-0000-0000-00000000000c');
select is((select row(u.unread_conversations, u.requests)::text from public.unread_message_counts() u), '(0,1)',
  'Cat still has Ann''s message request');

select * from finish();
rollback;
