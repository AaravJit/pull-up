-- Blocks and mutes stop pushes even for notifications made before them
-- (20261018000300_push_guard.sql).

begin;
create extension if not exists pgtap with schema extensions;
select plan(8);

insert into auth.users (id, email, raw_user_meta_data) values
  ('e8000000-0000-0000-0000-00000000000a', 'nina8@example.com', '{"username":"nina8"}'),
  ('e8000000-0000-0000-0000-00000000000b', 'omar8@example.com', '{"username":"omar8"}'),
  ('e8000000-0000-0000-0000-00000000000c', 'pat8@example.com', '{"username":"pat8"}');

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

create or replace function pg_temp.pushed(n uuid) returns boolean language sql as $$
  select allowed from public.push_content(n)
$$;

create temporary table ids (name text primary key, id uuid) on commit drop;
grant all on ids to authenticated;

-- Nina follows Omar, so his message is an accepted conversation. Pat is a
-- stranger who liked her post.
select pg_temp.act_as('e8000000-0000-0000-0000-00000000000a');
insert into public.follows (follower_id, followee_id) values (auth.uid(), 'e8000000-0000-0000-0000-00000000000b');
select pg_temp.act_as('e8000000-0000-0000-0000-00000000000b');
insert into ids values ('chat', public.start_conversation('e8000000-0000-0000-0000-00000000000a'));
insert into public.messages (conversation_id, sender_id, body) values ((select id from ids where name = 'chat'), auth.uid(), 'Ride Sunday?');
select pg_temp.act_as('e8000000-0000-0000-0000-00000000000a');
insert into public.messages (conversation_id, sender_id, body) values ((select id from ids where name = 'chat'), auth.uid(), 'Yes');

select pg_temp.as_admin();
insert into ids select 'to nina', id from public.notifications
  where recipient_id = 'e8000000-0000-0000-0000-00000000000a' and kind = 'message';
insert into ids select 'to omar', id from public.notifications
  where recipient_id = 'e8000000-0000-0000-0000-00000000000b' and kind = 'message';
insert into public.notifications (id, recipient_id, actor_id, kind) values
  ('e8400000-0000-0000-0000-000000000001', 'e8000000-0000-0000-0000-00000000000a', 'e8000000-0000-0000-0000-00000000000c', 'like');

-- 1–4: muting --------------------------------------------------------------------
select is(pg_temp.pushed((select id from ids where name = 'to nina')), true, 'a message is pushed');
select pg_temp.act_as('e8000000-0000-0000-0000-00000000000a');
select public.set_conversation_muted((select id from ids where name = 'chat'), true);
select pg_temp.as_admin();
select is(pg_temp.pushed((select id from ids where name = 'to nina')), false,
  'muting the chat stops a push that was already queued');
select is(pg_temp.pushed((select id from ids where name = 'to omar')), true,
  'Nina muting the chat does not mute it for Omar');
select pg_temp.act_as('e8000000-0000-0000-0000-00000000000a');
select public.set_conversation_muted((select id from ids where name = 'chat'), false);
select pg_temp.as_admin();
select is(pg_temp.pushed((select id from ids where name = 'to nina')), true, 'unmuting brings pushes back');

-- 5–8: blocking, either way round ---------------------------------------------------------
select is(pg_temp.pushed('e8400000-0000-0000-0000-000000000001'), true, 'a like is pushed');
select pg_temp.act_as('e8000000-0000-0000-0000-00000000000a');
insert into public.blocks (blocker_id, blocked_id) values (auth.uid(), 'e8000000-0000-0000-0000-00000000000c');
select pg_temp.as_admin();
select is(pg_temp.pushed('e8400000-0000-0000-0000-000000000001'), false,
  'blocking someone stops pushes about what they did before the block');
select pg_temp.act_as('e8000000-0000-0000-0000-00000000000b');
insert into public.blocks (blocker_id, blocked_id) values (auth.uid(), 'e8000000-0000-0000-0000-00000000000a');
select pg_temp.as_admin();
select is(pg_temp.pushed((select id from ids where name = 'to nina')), false,
  'someone who blocked you cannot reach you by push');
select is(pg_temp.pushed((select id from ids where name = 'to omar')), false,
  'nor can the person they blocked');

select * from finish();
rollback;
