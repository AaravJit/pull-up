-- Push preferences and device tokens: the server honours each person's
-- switches, keeps message text off lock screens unless asked, and a phone's
-- token follows whoever signed in last.

begin;
create extension if not exists pgtap with schema extensions;
select plan(24);

insert into auth.users (id, email, raw_user_meta_data) values
  ('e1000000-0000-0000-0000-00000000000a', 'nina@example.com', '{"username":"nina"}'),
  ('e1000000-0000-0000-0000-00000000000b', 'omar@example.com', '{"username":"omar"}'),
  ('e1000000-0000-0000-0000-00000000000c', 'pat@example.com', '{"username":"pat"}');
-- These accounts confirmed the minimum age and accepted the current terms
-- (20261025000400); 040/041 test what happens without that.
insert into public.terms_acceptances (user_id, version)
select p.id, v.version from public.profiles p, public.terms_versions v where v.is_current on conflict do nothing;
insert into private.age_checks (user_id, meets_minimum, minimum_age, method)
select id, true, 13, 'self_declared' from public.profiles on conflict do nothing;
update public.profiles set display_name = 'Omar K' where id = 'e1000000-0000-0000-0000-00000000000b';

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

create temporary table ids (name text primary key, id uuid) on commit drop;
grant all on ids to authenticated;

-- Nina follows Omar, so his messages land in her inbox; Pat is a stranger.
select pg_temp.act_as('e1000000-0000-0000-0000-00000000000a');
insert into public.follows (follower_id, followee_id) values ('e1000000-0000-0000-0000-00000000000a', 'e1000000-0000-0000-0000-00000000000b');
select pg_temp.act_as('e1000000-0000-0000-0000-00000000000b');
insert into ids values ('on', public.start_conversation('e1000000-0000-0000-0000-00000000000a'));
insert into public.messages (id, conversation_id, sender_id, body) values
  ('e3000000-0000-0000-0000-000000000001', (select id from ids where name = 'on'), auth.uid(), '  Meet at   the  usual spot? ');
select pg_temp.act_as('e1000000-0000-0000-0000-00000000000c');
insert into ids values ('pn', public.start_conversation('e1000000-0000-0000-0000-00000000000a'));
insert into public.messages (conversation_id, sender_id, body) values
  ((select id from ids where name = 'pn'), auth.uid(), 'hey, nice bike, here is my number');

select pg_temp.as_admin();
insert into ids select 'msg', id from public.notifications
  where recipient_id = 'e1000000-0000-0000-0000-00000000000a' and kind = 'message';
insert into ids select 'req', id from public.notifications
  where recipient_id = 'e1000000-0000-0000-0000-00000000000a' and kind = 'message_request';
insert into public.notifications (id, recipient_id, actor_id, kind) values
  ('e4000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-00000000000a', 'e1000000-0000-0000-0000-00000000000c', 'like'),
  ('e4000000-0000-0000-0000-000000000002', 'e1000000-0000-0000-0000-00000000000a', 'e1000000-0000-0000-0000-00000000000c', 'follow');

-- 1–2: only the server asks -------------------------------------------------------
select pg_temp.act_as('e1000000-0000-0000-0000-00000000000a');
select throws_ok($$ select * from public.push_content((select id from ids where name = 'msg')) $$,
  '42501', null, 'people cannot ask what a push would say');
select set_config('role', 'anon', true);
select throws_ok($$ select public.register_device_token(repeat('cd', 32), 'production') $$, '42501', null,
  'signed-out callers cannot register a phone');
select pg_temp.act_as('e1000000-0000-0000-0000-00000000000a');

-- 3–7: defaults: everything pushed, no message text ---------------------------------------
select pg_temp.as_admin();
select is((select allowed from public.push_content((select id from ids where name = 'msg'))), true,
  'messages are pushed by default');
select is((select preview from public.push_content((select id from ids where name = 'msg'))), null,
  'message text is not in pushes by default');
select is((select actor_name from public.push_content((select id from ids where name = 'msg'))), 'Omar K',
  'the push names the sender');
select is((select actor_name from public.push_content('e4000000-0000-0000-0000-000000000001')), '@pat',
  'falls back to the username without a display name');
select is((select count(*)::int from public.push_content('e4000000-0000-0000-0000-0000000000ff')), 0,
  'an unknown notification gives nothing to push');

-- 8–11: previews, when asked, only for accepted conversations ----------------------------------
select pg_temp.act_as('e1000000-0000-0000-0000-00000000000a');
insert into public.notification_preferences (message_previews) values (true);
select pg_temp.as_admin();
select is((select preview from public.push_content((select id from ids where name = 'msg'))), 'Meet at the usual spot?',
  'with previews on, the message text is included (tidied)');
select is((select preview from public.push_content((select id from ids where name = 'req'))), null,
  'a message request never shows its text, even with previews on');
select is((select allowed from public.push_content((select id from ids where name = 'req'))), true,
  'requests are still pushed by default');
select pg_temp.act_as('e1000000-0000-0000-0000-00000000000b');
select public.unsend_message('e3000000-0000-0000-0000-000000000001');
select pg_temp.as_admin();
select is((select preview from public.push_content((select id from ids where name = 'msg'))), null,
  'an unsent message is never previewed');

-- 12–15: switches ------------------------------------------------------------------------
select pg_temp.act_as('e1000000-0000-0000-0000-00000000000a');
update public.notification_preferences set messages = false, likes_comments = false where user_id = auth.uid();
select pg_temp.as_admin();
select is((select allowed from public.push_content((select id from ids where name = 'msg'))), false,
  'turning messages off stops message pushes');
select is((select allowed from public.push_content((select id from ids where name = 'req'))), true,
  'requests have their own switch');
select is((select allowed from public.push_content('e4000000-0000-0000-0000-000000000001')), false,
  'turning likes and comments off stops like pushes');
select is((select allowed from public.push_content('e4000000-0000-0000-0000-000000000002')), true,
  'followers are unaffected');

-- 16–18: preferences are private -----------------------------------------------------------
select pg_temp.act_as('e1000000-0000-0000-0000-00000000000b');
select is((select count(*)::int from public.notification_preferences), 0, 'nobody sees another person''s preferences');
update public.notification_preferences set messages = true where user_id = 'e1000000-0000-0000-0000-00000000000a';
select throws_ok($$
  insert into public.notification_preferences (user_id, messages) values ('e1000000-0000-0000-0000-00000000000a', true)
$$, '42501', null, 'nobody can create preferences for someone else');
select pg_temp.as_admin();
select is((select messages from public.notification_preferences where user_id = 'e1000000-0000-0000-0000-00000000000a'), false,
  'nobody can change someone else''s preferences');

-- 19–24: device tokens follow the signed-in account ------------------------------------------
select pg_temp.act_as('e1000000-0000-0000-0000-00000000000a');
select throws_ok($$
  insert into public.device_tokens (token, user_id, platform) values (repeat('ab', 32), auth.uid(), 'ios')
$$, '42501', null, 'tokens are only registered through register_device_token');
select throws_ok($$ select public.register_device_token('not-a-token', 'production') $$, '22023', null,
  'malformed tokens are refused');
select public.register_device_token(upper(repeat('ab', 32)), 'sandbox');
select pg_temp.act_as('e1000000-0000-0000-0000-00000000000b');
select public.register_device_token(repeat('ab', 32), 'production');
select pg_temp.act_as('e1000000-0000-0000-0000-00000000000a');
select is((select count(*)::int from public.device_tokens), 0,
  'when someone else signs in on the phone, the token moves to them');
select public.unregister_device_token(repeat('ab', 32));
select pg_temp.as_admin();
select is((select user_id from public.device_tokens where token = repeat('ab', 32)), 'e1000000-0000-0000-0000-00000000000b'::uuid,
  'the previous account cannot unregister the new owner''s phone');
select pg_temp.act_as('e1000000-0000-0000-0000-00000000000b');
select public.unregister_device_token(repeat('ab', 32));
select is((select count(*)::int from public.device_tokens), 0, 'signing out unregisters the phone');
select pg_temp.act_as('e1000000-0000-0000-0000-00000000000c');
select public.register_device_token(lpad(to_hex(g), 64, '0'), 'production') from generate_series(1, 12) g;
select is((select count(*)::int from public.device_tokens), 10, 'each account keeps at most 10 phones');

select * from finish();
rollback;
