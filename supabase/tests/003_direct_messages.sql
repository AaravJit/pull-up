-- Direct messages: isolation, impersonation, blocks, requests, read
-- receipts, shared-object privacy, attachments, rate limits and reports.

begin;
create extension if not exists pgtap with schema extensions;
select plan(44);

insert into auth.users (id, email, raw_user_meta_data) values
  ('d1000000-0000-0000-0000-00000000000a', 'alice@example.com', '{"username":"alice"}'),
  ('d1000000-0000-0000-0000-00000000000b', 'bob@example.com', '{"username":"bob"}'),
  ('d1000000-0000-0000-0000-00000000000c', 'carol@example.com', '{"username":"carol"}'),
  ('d1000000-0000-0000-0000-00000000000d', 'dave@example.com', '{"username":"dave"}'),
  ('d1000000-0000-0000-0000-00000000000e', 'eve@example.com', '{"username":"eve"}');

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

-- Bob follows Alice; Dave only takes messages from people he follows; Alice blocks Eve.
select pg_temp.act_as('d1000000-0000-0000-0000-00000000000b');
insert into public.follows (follower_id, followee_id) values ('d1000000-0000-0000-0000-00000000000b', 'd1000000-0000-0000-0000-00000000000a');
select pg_temp.act_as('d1000000-0000-0000-0000-00000000000d');
update public.privacy_settings set messages_from = 'following' where user_id = auth.uid();
select pg_temp.act_as('d1000000-0000-0000-0000-00000000000a');
insert into public.blocks (blocker_id, blocked_id) values ('d1000000-0000-0000-0000-00000000000a', 'd1000000-0000-0000-0000-00000000000e');
insert into public.vehicles (id, owner_id, kind, make, model, year, visibility) values
  ('d2000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-00000000000a', 'motorcycle', 'Suzuki', 'GSX-R750', 2001, 'public'),
  ('d2000000-0000-0000-0000-000000000002', 'd1000000-0000-0000-0000-00000000000a', 'car', 'Mazda', 'RX-7', 1994, 'private');

-- 1–6: starting conversations ------------------------------------------------
create temporary table ids (name text primary key, id uuid) on commit drop;
grant all on ids to authenticated;
insert into ids values ('ab', public.start_conversation('d1000000-0000-0000-0000-00000000000b'));
select is(public.start_conversation('d1000000-0000-0000-0000-00000000000b'), (select id from ids where name = 'ab'),
  'one conversation per pair');
select is((select count(*)::int from public.conversation_members), 1, 'members see only their own membership row');

select pg_temp.act_as('d1000000-0000-0000-0000-00000000000c');
insert into ids values ('ca', public.start_conversation('d1000000-0000-0000-0000-00000000000a'));
select throws_ok($$ select public.start_conversation('d1000000-0000-0000-0000-00000000000d') $$, '42501', 'you can''t message this person',
  'people who only take messages from those they follow are protected');
select pg_temp.act_as('d1000000-0000-0000-0000-00000000000e');
select throws_ok($$ select public.start_conversation('d1000000-0000-0000-0000-00000000000a') $$, '42501', 'you can''t message this person',
  'a blocked person gets the same refusal, revealing nothing');
select throws_ok($$ select public.start_conversation('d1000000-0000-0000-0000-0000000000ff') $$, '42501', 'you can''t message this person',
  'a nonexistent account gets the same refusal');
select pg_temp.as_admin();
select is((select state from public.conversation_members where conversation_id = (select id from ids where name = 'ca')
  and user_id = 'd1000000-0000-0000-0000-00000000000a'), 'request', 'a stranger''s message lands in Requests');

-- 7–12: sending ---------------------------------------------------------------
select pg_temp.act_as('d1000000-0000-0000-0000-00000000000a');
insert into public.messages (id, conversation_id, sender_id, body) values
  ('d3000000-0000-0000-0000-000000000001', (select id from ids where name = 'ab'), auth.uid(), 'Sac Nights on Friday?');
select throws_ok($$ insert into public.messages (conversation_id, sender_id, body)
  values ((select id from ids where name = 'ab'), 'd1000000-0000-0000-0000-00000000000b', 'I am Bob') $$,
  '42501', null, 'cannot send as someone else');
select is((select created_at > now() - interval '1 minute' from public.messages where id = 'd3000000-0000-0000-0000-000000000001'), true,
  'the server sets the timestamp');

select pg_temp.act_as('d1000000-0000-0000-0000-00000000000c');
select throws_ok($$ insert into public.messages (conversation_id, sender_id, body)
  values ((select id from ids where name = 'ab'), auth.uid(), 'let me in') $$,
  '42501', null, 'cannot post into a conversation you are not in');
select is((select count(*)::int from public.messages where conversation_id = (select id from ids where name = 'ab')), 0,
  'cannot read a conversation you are not in');
select is((select count(*)::int from public.conversations), 1, 'conversations are not enumerable');
insert into public.messages (conversation_id, sender_id, body) values
  ((select id from ids where name = 'ca'), auth.uid(), 'hey'),
  ((select id from ids where name = 'ca'), auth.uid(), 'nice gixxer'),
  ((select id from ids where name = 'ca'), auth.uid(), 'selling?');
select throws_ok($$ insert into public.messages (conversation_id, sender_id, body)
  values ((select id from ids where name = 'ca'), auth.uid(), 'hello??') $$,
  '54000', null, 'a request allows three messages until it is accepted');

-- 13–18: inbox, requests, read receipts ------------------------------------------
select pg_temp.act_as('d1000000-0000-0000-0000-00000000000a');
select is((select count(*)::int from public.inbox('request')), 1, 'the request shows under Requests');
select is((select unread_count from public.inbox('request')), 3, 'requests count unread messages');
select is((select count(*)::int from public.notifications where kind = 'message_request'), 3, 'requests notify without content');
select public.mark_conversation_read((select id from ids where name = 'ca'));
select pg_temp.act_as('d1000000-0000-0000-0000-00000000000c');
select is(public.peer_read_at((select id from ids where name = 'ca')), null, 'opening a request sends no read receipt');
select pg_temp.act_as('d1000000-0000-0000-0000-00000000000a');
insert into public.messages (conversation_id, sender_id, body) values ((select id from ids where name = 'ca'), auth.uid(), 'not selling, sorry');
select is((select count(*)::int from public.inbox('request')), 0, 'replying accepts the request');

select pg_temp.act_as('d1000000-0000-0000-0000-00000000000b');
select is((select unread_count from public.inbox('active')), 1, 'unread count for the recipient');
select public.mark_conversation_read((select id from ids where name = 'ab'));
select is((select unread_count from public.inbox('active')), 0, 'reading clears the unread count');

-- 19–21
select pg_temp.act_as('d1000000-0000-0000-0000-00000000000a');
select isnt(public.peer_read_at((select id from ids where name = 'ab')), null, 'read receipts show when both share them');
select pg_temp.act_as('d1000000-0000-0000-0000-00000000000b');
update public.privacy_settings set dm_read_receipts = false where user_id = auth.uid();
select pg_temp.act_as('d1000000-0000-0000-0000-00000000000a');
select is(public.peer_read_at((select id from ids where name = 'ab')), null, 'turning receipts off hides your read time');
select is((select count(*)::int from public.conversation_members where user_id = 'd1000000-0000-0000-0000-00000000000b'), 0,
  'the peer''s membership row (read time, mute) is never readable');

-- 22–26: shared objects and attachments --------------------------------------------
insert into public.messages (conversation_id, sender_id, body, shared_kind, shared_id) values
  ((select id from ids where name = 'ab'), auth.uid(), 'this one', 'vehicle', 'd2000000-0000-0000-0000-000000000001'),
  ((select id from ids where name = 'ab'), auth.uid(), '', 'vehicle', 'd2000000-0000-0000-0000-000000000002');
select pg_temp.act_as('d1000000-0000-0000-0000-00000000000b');
select is((public.shared_preview('vehicle', 'd2000000-0000-0000-0000-000000000001') ->> 'title'), '2001 Suzuki GSX-R750',
  'a public vehicle previews for the recipient');
select is((public.shared_preview('vehicle', 'd2000000-0000-0000-0000-000000000002') ->> 'available'), 'false',
  'sharing a private vehicle does not make it visible to the recipient');
select throws_ok($$ insert into public.messages (conversation_id, sender_id, body, shared_kind, shared_id)
  values ((select id from ids where name = 'ab'), auth.uid(), 'look', 'vehicle', 'd2000000-0000-0000-0000-000000000002') $$,
  '42501', null, 'cannot share something you cannot see');
select throws_ok(format($$ insert into public.messages (conversation_id, sender_id, media_path)
  values ('%s', auth.uid(), '%s/d1000000-0000-0000-0000-00000000000b/x.jpg') $$,
  (select id from ids where name = 'ab'), (select id from ids where name = 'ca')),
  '42501', null, 'a photo must come from this conversation''s folder');
select throws_ok(format($$ insert into storage.objects (bucket_id, name) values ('dm-media', '%s/d1000000-0000-0000-0000-00000000000b/x.jpg') $$,
  (select id from ids where name = 'ca')),
  '42501', null, 'cannot upload into someone else''s conversation');

-- 27–31: editing, unsending, reactions -------------------------------------------
select throws_ok($$ update public.messages set body = 'edited' where id = 'd3000000-0000-0000-0000-000000000001' $$,
  '42501', null, 'messages cannot be edited');
select throws_ok($$ select public.unsend_message('d3000000-0000-0000-0000-000000000001') $$,
  '42501', null, 'cannot unsend someone else''s message');
insert into public.message_reactions (message_id, user_id, emoji) values ('d3000000-0000-0000-0000-000000000001', auth.uid(), '🔥');
select throws_ok($$ insert into public.message_reactions (message_id, user_id, emoji)
  values ('d3000000-0000-0000-0000-000000000001', auth.uid(), '💩') $$,
  '23514', null, 'only the fixed reaction set');
select pg_temp.act_as('d1000000-0000-0000-0000-00000000000c');
select throws_ok($$ insert into public.message_reactions (message_id, user_id, emoji)
  values ('d3000000-0000-0000-0000-000000000001', auth.uid(), '👍') $$,
  '42501', null, 'outsiders cannot react');
select pg_temp.act_as('d1000000-0000-0000-0000-00000000000a');
select public.unsend_message('d3000000-0000-0000-0000-000000000001');
select is((select body from public.messages where id = 'd3000000-0000-0000-0000-000000000001'), '',
  'unsending clears the content');

-- 32–34: reports -------------------------------------------------------------------
select isnt(public.report_user('d1000000-0000-0000-0000-00000000000c', 'spam', 'asked three times',
  (select id from public.messages where body = 'selling?')), null, 'a message can be reported');
select is((select snapshot ->> 'body' from public.reports), 'selling?', 'the report keeps a copy of the message');
select pg_temp.act_as('d1000000-0000-0000-0000-00000000000c');
select is((select count(*)::int from public.reports), 0, 'the reported person cannot see reports about them');

-- 35–37: blocks after the fact ------------------------------------------------------
select pg_temp.act_as('d1000000-0000-0000-0000-00000000000b');
insert into public.blocks (blocker_id, blocked_id) values ('d1000000-0000-0000-0000-00000000000b', 'd1000000-0000-0000-0000-00000000000a');
select pg_temp.act_as('d1000000-0000-0000-0000-00000000000a');
select throws_ok($$ insert into public.messages (conversation_id, sender_id, body)
  values ((select id from ids where name = 'ab'), auth.uid(), 'why') $$,
  '42501', 'you can''t message this person', 'a block stops messages in an existing conversation');
select is((select count(*)::int from public.messages where conversation_id = (select id from ids where name = 'ab')), 0,
  'a block hides the conversation''s messages');
select is((select count(*)::int from public.inbox('active') where peer_username = 'bob'), 0, 'and removes it from the inbox');

-- 38–40: suspensions, mute and rate limits ---------------------------------------------
select pg_temp.as_admin();
-- Pauses live in private.messaging_pauses since 20261025000330.
insert into private.messaging_pauses (user_id, paused_until) values ('d1000000-0000-0000-0000-00000000000c', now() + interval '1 day');
select pg_temp.act_as('d1000000-0000-0000-0000-00000000000c');
select throws_ok($$ insert into public.messages (conversation_id, sender_id, body)
  values ((select id from ids where name = 'ca'), auth.uid(), 'still here') $$,
  '42501', null, 'a suspended account cannot send');
update public.profiles set messaging_suspended_until = null where id = auth.uid();
select pg_temp.as_admin();
select isnt((select paused_until from private.messaging_pauses where user_id = 'd1000000-0000-0000-0000-00000000000c'), null,
  'people cannot lift their own suspension');
delete from private.messaging_pauses where user_id = 'd1000000-0000-0000-0000-00000000000c';

select pg_temp.act_as('d1000000-0000-0000-0000-00000000000a');
insert into public.messages (conversation_id, sender_id, body)
  select (select id from ids where name = 'ca'), auth.uid(), 'msg ' || g from generate_series(1, 26) g;
select throws_ok($$ insert into public.messages (conversation_id, sender_id, body)
  values ((select id from ids where name = 'ca'), auth.uid(), 'one too many') $$,
  '54000', null, 'per-minute rate limit');

-- 42–44: retention ------------------------------------------------------------------
select throws_ok($$ select * from public.dm_purge() $$, '42501', null, 'people cannot run the retention purge');
select pg_temp.as_admin();
update public.conversation_members set cleared_at = now() where conversation_id = (select id from ids where name = 'ca');
select lives_ok($$ select * from public.dm_purge() $$, 'the retention purge runs');
select is((select count(*)::int from public.messages where conversation_id = (select id from ids where name = 'ca')), 0,
  'history both people deleted is purged');

select * from finish();
rollback;
