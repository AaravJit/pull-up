-- Blocking, as the blocked person sees it: direct REST/RPC requests can't
-- get around a block. Ann blocks Ben after they had followed each other,
-- talked, and Ben had RSVPed to Ann's meet.

begin;
create extension if not exists pgtap with schema extensions;
select plan(24);

insert into auth.users (id, email, raw_user_meta_data) values
  ('f3300000-0000-0000-0000-00000000000a'::uuid, 'be-ann@example.com', '{"username":"be_ann"}'),
  ('f3300000-0000-0000-0000-00000000000b'::uuid, 'be-ben@example.com', '{"username":"be_ben"}');

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

insert into public.follows (follower_id, followee_id) values
  ('f3300000-0000-0000-0000-00000000000a', 'f3300000-0000-0000-0000-00000000000b'),
  ('f3300000-0000-0000-0000-00000000000b', 'f3300000-0000-0000-0000-00000000000a');
insert into public.posts (id, author_id, caption, visibility) values
  ('f3310000-0000-0000-0000-000000000001', 'f3300000-0000-0000-0000-00000000000a', 'Ann''s post', 'public');
insert into public.vehicles (id, owner_id, kind, make, model, year, visibility) values
  ('f3320000-0000-0000-0000-000000000001', 'f3300000-0000-0000-0000-00000000000a', 'car', 'Honda', 'S2000', 2004, 'public');
insert into public.meets (id, host_id, title, starts_at, ends_at, venue_name, lat, lon) values
  ('f3330000-0000-0000-0000-000000000001', 'f3300000-0000-0000-0000-00000000000a', 'Ann''s meet',
   now() + interval '1 day', now() + interval '1 day 2 hours', 'Lot', 1, 1);
insert into public.meet_rsvps (meet_id, user_id, status, show_me) values
  ('f3330000-0000-0000-0000-000000000001', 'f3300000-0000-0000-0000-00000000000b', 'interested', true);

select pg_temp.act_as('f3300000-0000-0000-0000-00000000000b');
create temp table conv on commit drop as select public.start_conversation('f3300000-0000-0000-0000-00000000000a') as id;
grant select on conv to authenticated;
insert into public.messages (id, conversation_id, sender_id, body)
select 'f3340000-0000-0000-0000-000000000001', id, auth.uid(), 'hey' from conv;

select pg_temp.act_as('f3300000-0000-0000-0000-00000000000a');
insert into public.blocks (blocker_id, blocked_id) values (auth.uid(), 'f3300000-0000-0000-0000-00000000000b');

-- Now everything below runs as Ben, the blocked person.
select pg_temp.act_as('f3300000-0000-0000-0000-00000000000b');

-- Reads
select is((select count(*)::int from public.profiles where id = 'f3300000-0000-0000-0000-00000000000a'), 0, 'Ben can''t read Ann''s profile row');
select is(public.get_profile('f3300000-0000-0000-0000-00000000000a'), null, 'or her profile page');
select is((select count(*)::int from public.profile_details where user_id = 'f3300000-0000-0000-0000-00000000000a'), 0, 'or her bio');
select is((select count(*)::int from public.posts where author_id = 'f3300000-0000-0000-0000-00000000000a'), 0, 'or her posts');
select is((select count(*)::int from public.vehicles where owner_id = 'f3300000-0000-0000-0000-00000000000a'), 0, 'or her garage');
select is((select count(*)::int from public.meets where host_id = 'f3300000-0000-0000-0000-00000000000a'), 0, 'or her meets');
select is((select count(*)::int from public.messages where conversation_id = (select id from conv)), 0, 'or their old messages');
select is((select count(*)::int from public.inbox('active')), 0, 'and the conversation leaves his inbox');
select is((select count(*)::int from public.follows where followee_id = 'f3300000-0000-0000-0000-00000000000a' or follower_id = 'f3300000-0000-0000-0000-00000000000a'), 0, 'the follows are gone');

-- Writes
select throws_ok($$ insert into public.follows (follower_id, followee_id) values (auth.uid(), 'f3300000-0000-0000-0000-00000000000a') $$, '42501', null, 'he can''t follow her again');
select throws_ok($$ select public.start_conversation('f3300000-0000-0000-0000-00000000000a') $$, '42501', 'you can''t message this person', 'or start a conversation');
select throws_ok($$ insert into public.messages (conversation_id, sender_id, body) select id, auth.uid(), 'still here' from conv $$, '42501', null, 'or write in the old one');
select throws_ok($$ insert into public.message_reactions (message_id, user_id, emoji) values ('f3340000-0000-0000-0000-000000000001', auth.uid(), '👍') $$, '42501', null, 'or react to an old message');
select throws_ok($$ insert into public.comments (post_id, author_id, body) values ('f3310000-0000-0000-0000-000000000001', auth.uid(), 'hi') $$, '42501', null, 'or comment on her post');
select throws_ok($$ insert into public.likes (post_id, user_id) values ('f3310000-0000-0000-0000-000000000001', auth.uid()) $$, '42501', null, 'or like it');
select throws_ok($$ insert into public.meet_rsvps (meet_id, user_id, status) values ('f3330000-0000-0000-0000-000000000001', auth.uid(), 'going') on conflict (meet_id, user_id) do update set status = 'going' $$, '42501', null, 'or RSVP to her meet');
select throws_ok($$ update public.meet_rsvps set status = 'going' where meet_id = 'f3330000-0000-0000-0000-000000000001' and user_id = auth.uid() $$, '42501', 'you can''t join this meet', 'or change the RSVP he made before the block');
select is(public.shared_preview('post', 'f3310000-0000-0000-0000-000000000001') ->> 'available', 'false', 'her post shows as unavailable in a chat');
select is(public.shared_preview('vehicle', 'f3320000-0000-0000-0000-000000000001') ->> 'available', 'false', 'a shared card of hers shows as unavailable');
select is((select count(*)::int from public.meet_attendees('f3330000-0000-0000-0000-000000000001')), 0, 'and her meet''s attendee list is closed');
delete from public.blocks where blocker_id = 'f3300000-0000-0000-0000-00000000000a';
select is((select count(*)::int from public.blocks), 0, 'he can''t see her block');
select is(public.is_blocked_between('f3300000-0000-0000-0000-00000000000a', 'f3300000-0000-0000-0000-00000000000b'), true, 'though he is told he is blocked when he asks about himself');
-- His delete above changed nothing, and Ann can still report him.
select pg_temp.act_as('f3300000-0000-0000-0000-00000000000a');
select is((select count(*)::int from public.blocks), 1, 'he couldn''t lift her block');
select lives_ok($$ select public.report_user('f3300000-0000-0000-0000-00000000000b', 'harassment') $$, 'the blocker can still report the person she blocked');

select * from finish();
rollback;
