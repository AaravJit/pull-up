-- Security assessment regressions (docs/SECURITY_REPORT.md). Synthetic users
-- on the local stack only. Each block names the finding it guards.

begin;
create extension if not exists pgtap with schema extensions;
select plan(20);

insert into auth.users (id, email, raw_user_meta_data) values
  ('f1000000-0000-0000-0000-00000000000a', 'sec-ann@example.com', '{"username":"sec_ann"}'),
  ('f1000000-0000-0000-0000-00000000000b', 'sec-ben@example.com', '{"username":"sec_ben"}'),
  ('f1000000-0000-0000-0000-00000000000c', 'sec-cat@example.com', '{"username":"sec_cat"}');

create or replace function pg_temp.act_as(uid uuid) returns void language plpgsql as $$
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', uid::text, true);
end $$;

create or replace function pg_temp.as_anon() returns void language plpgsql as $$
begin
  perform set_config('role', 'anon', true);
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  perform set_config('request.jwt.claim.sub', '', true);
end $$;

create or replace function pg_temp.as_admin() returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
end $$;

-- Ann has a private drive with a track; Ann blocked Cat; Ann and Ben follow
-- each other with private profiles.
select pg_temp.act_as('f1000000-0000-0000-0000-00000000000a');
update public.profiles set visibility = 'private' where id = auth.uid();
insert into public.blocks (blocker_id, blocked_id) values (auth.uid(), 'f1000000-0000-0000-0000-00000000000c');
insert into public.follows (follower_id, followee_id) values (auth.uid(), 'f1000000-0000-0000-0000-00000000000b');
insert into public.drives (id, owner_id, started_at, ended_at, distance_m, moving_s, stopped_s, elapsed_s, top_speed_mps, visibility)
values ('f2000000-0000-0000-0000-000000000001', auth.uid(), now() - interval '1 hour', now() - interval '1 hour' + interval '199 seconds',
        4426, 199, 0, 199, 22.2, 'private');
insert into public.drive_tracks (drive_id, owner_id, points)
select 'f2000000-0000-0000-0000-000000000001', auth.uid(),
  jsonb_agg(jsonb_build_array(i, 38.58 + i * 0.0002, -121.49, 20, 22.2, 5, 4, 0.5) order by i)
from generate_series(0, 199) as i;
select pg_temp.act_as('f1000000-0000-0000-0000-00000000000b');
update public.profiles set visibility = 'private' where id = auth.uid();
insert into public.follows (follower_id, followee_id) values (auth.uid(), 'f1000000-0000-0000-0000-00000000000a');
select pg_temp.act_as('f1000000-0000-0000-0000-00000000000a');
update public.follows set status = 'accepted' where followee_id = auth.uid();
select pg_temp.act_as('f1000000-0000-0000-0000-00000000000b');
update public.follows set status = 'accepted' where followee_id = auth.uid();

-- 1–3: SEC-01 internal helpers callable by any signed-in user -------------------------
select pg_temp.act_as('f1000000-0000-0000-0000-00000000000c');
select throws_ok($$ select private.build_shared_route('f2000000-0000-0000-0000-000000000001') $$, '42501', null,
  'SEC-01: nobody can build the route of someone else''s private drive');
select throws_ok($$ select private.notify('f1000000-0000-0000-0000-00000000000b', 'f1000000-0000-0000-0000-00000000000a', 'follow') $$,
  '42501', null, 'SEC-01: nobody can forge a notification from someone else');
select throws_ok($$ select private.validate_drive('f2000000-0000-0000-0000-000000000001') $$, '42501', null,
  'SEC-01: nobody can read another drive''s validation');

-- 4–7: SEC-02 relationship oracles ------------------------------------------------
select is(public.is_blocked_between('f1000000-0000-0000-0000-00000000000a', 'f1000000-0000-0000-0000-00000000000b'), false,
  'SEC-02: a third party learns nothing about other people''s blocks (control)');
select pg_temp.act_as('f1000000-0000-0000-0000-00000000000b');
select is(public.is_blocked_between('f1000000-0000-0000-0000-00000000000a', 'f1000000-0000-0000-0000-00000000000c'), false,
  'SEC-02: Ben cannot find out that Ann blocked Cat');
select is(public.is_friend('f1000000-0000-0000-0000-00000000000a', 'f1000000-0000-0000-0000-00000000000b'), true,
  'is_friend still answers for one of the two people');
select pg_temp.act_as('f1000000-0000-0000-0000-00000000000c');
select is(public.is_friend('f1000000-0000-0000-0000-00000000000a', 'f1000000-0000-0000-0000-00000000000b'), false,
  'SEC-02: Cat cannot find out that two private accounts are friends');

-- 8–9: blocking still works where it matters ------------------------------------------
select pg_temp.act_as('f1000000-0000-0000-0000-00000000000c');
select is(public.is_blocked_between('f1000000-0000-0000-0000-00000000000a', auth.uid()), true,
  'the blocked person''s own checks still see the block');
select throws_ok($$ select public.start_conversation('f1000000-0000-0000-0000-00000000000a') $$, '42501', null,
  'and still cannot message the person who blocked them');

-- 10–11: SEC-03 DM membership helpers only answer about yourself -------------------------
select pg_temp.act_as('f1000000-0000-0000-0000-00000000000a');
create temporary table ids (name text primary key, id uuid) on commit drop;
grant all on ids to authenticated;
insert into ids values ('ab', public.start_conversation('f1000000-0000-0000-0000-00000000000b'));
select pg_temp.act_as('f1000000-0000-0000-0000-00000000000c');
select is(private.peer_of((select id from ids where name = 'ab'), 'f1000000-0000-0000-0000-00000000000a'), null,
  'SEC-03: knowing a conversation id doesn''t reveal who is in it');
select is(private.is_member((select id from ids where name = 'ab'), 'f1000000-0000-0000-0000-00000000000b'), false,
  'SEC-03: nor whether someone else is a member');

-- 12–14: SEC-04 nothing in the API is callable signed out -------------------------------
select pg_temp.as_anon();
select throws_ok($$ select public.is_blocked_between('f1000000-0000-0000-0000-00000000000a', 'f1000000-0000-0000-0000-00000000000c') $$,
  '42501', null, 'SEC-04: signed-out callers cannot probe blocks');
select throws_ok($$ select public.drive_history_ceiling('f1000000-0000-0000-0000-00000000000a') $$, '42501', null,
  'SEC-04: signed-out callers cannot read privacy settings');
select pg_temp.as_admin();
select is(
  (select coalesce(array_agg(p.proname::text order by p.proname), '{}')
   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
     and p.prorettype <> 'trigger'::regtype),
  '{}'::text[], 'SEC-04: no public function is executable by anon (and anon has no access to private)');

-- 15–20: structural checks so new code can't quietly reopen these ---------------------------
select is(
  (select coalesce(array_agg(c.relname::text order by c.relname), '{}') from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity),
  '{}'::text[], 'every public table has row level security on');
select is(
  (select coalesce(array_agg(n.nspname || '.' || p.proname order by 1), '{}') from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public', 'private') and p.prosecdef
     and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) cfg where cfg like 'search_path=%')),
  '{}'::text[], 'every security definer function pins its search_path');
select is(
  (select coalesce(array_agg(p.proname::text order by p.proname), '{}') from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'private' and p.prosecdef and p.prorettype <> 'trigger'::regtype
     and has_function_privilege('authenticated', p.oid, 'execute')),
  array['can_read_message', 'can_view_shared', 'dm_path_member', 'is_member', 'peer_of', 'username_problem']::text[],
  'only reviewed private definer helpers are callable by signed-in users (they answer for the caller only)');
select is(
  (select coalesce(array_agg(tablename || ':' || policyname order by 1), '{}') from pg_policies
   where schemaname = 'public' and not (roles <@ array['authenticated']::name[])),
  '{}'::text[], 'every public policy applies to signed-in users only');
select ok(not has_schema_privilege('anon', 'private', 'usage') and (select count(*) = 0 from storage.buckets where public),
  'anon cannot reach the private schema, and no storage bucket is public');
select is(
  (select coalesce(array_agg(c.relname::text order by c.relname), '{}') from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r'
     and (has_table_privilege('anon', c.oid, 'insert') or has_table_privilege('anon', c.oid, 'update')
          or has_table_privilege('anon', c.oid, 'delete'))
     and exists (select 1 from pg_policies pol where pol.schemaname = 'public' and pol.tablename = c.relname and 'anon' = any (pol.roles))),
  '{}'::text[], 'no table has a write policy for signed-out callers');

select * from finish();
rollback;
