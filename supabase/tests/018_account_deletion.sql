-- Account deletion (App Store Review Guideline 5.1.1(v)): deleting the auth
-- user, which is what delete-account does after removing Storage files,
-- leaves no row that still names the account, keeps everyone else's own
-- data, and stops a still-valid token from uploading files afterwards.

begin;
create extension if not exists pgtap with schema extensions;
select plan(20);

-- Zed deletes their account; Amy stays.
insert into auth.users (id, email, raw_user_meta_data) values
  ('de000000-0000-0000-0000-00000000000a', 'del-amy@example.com', '{"username":"del_amy"}'),
  ('de000000-0000-0000-0000-00000000000f', 'del-zed@example.com', '{"username":"del_zed"}');
-- These accounts confirmed the minimum age and accepted the current terms
-- (20261025000400); 040/041 test what happens without that.
insert into public.terms_acceptances (user_id, version)
select p.id, v.version from public.profiles p, public.terms_versions v where v.is_current on conflict do nothing;
insert into private.age_checks (user_id, meets_minimum, minimum_age, method)
select id, true, 13, 'self_declared' from public.profiles on conflict do nothing;
insert into auth.identities (user_id, provider, provider_id, identity_data) values
  ('de000000-0000-0000-0000-00000000000f', 'apple', '001234.zed', '{"sub": "001234.zed"}');

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

-- 1–2: no reference to an account can block or survive its deletion -------

select is(
  (select count(*)::int from pg_constraint c
    where c.contype = 'f' and c.confrelid in ('public.profiles'::regclass, 'auth.users'::regclass)
      and c.connamespace::regnamespace::text in ('public', 'private')
      and c.confdeltype not in ('c', 'n')),
  0, 'every foreign key to an account cascades or is cleared when the account is deleted');

-- Columns that hold an account id without a foreign key would survive the
-- delete. Only these are known:
-- * profiles.id is the account itself.
-- * private.moderation_audit (moderation PR) keeps actor and subject ids on
--   purpose: it is the append-only record of moderator actions, kept two
--   years and disclosed in the privacy policy. The ids point at nothing once
--   the account is gone. A foreign key would either block deletion or
--   rewrite the append-only log.
select is(
  (select array_agg(format('%s.%s', a.attrelid::regclass, a.attname) order by 1)
     from pg_attribute a
     join pg_class t on t.oid = a.attrelid and t.relkind = 'r'
    where t.relnamespace::regnamespace::text in ('public', 'private')
      and a.attnum > 0 and not a.attisdropped
      and a.atttypid = 'uuid'::regtype
      and a.attname ~ '(^|_)(user|owner|author|sender|recipient|actor|host|reporter|subject|follower|followee|blocker|blocked|created_by|user_a|user_b|moderator)(_id)?$'
      and not exists (select 1 from pg_constraint c where c.contype = 'f' and c.conrelid = a.attrelid and a.attnum = any(c.conkey))
      and not (t.relname = 'profiles' and a.attname = 'id')
      and not (t.relnamespace = 'private'::regnamespace and t.relname = 'moderation_audit'
               and a.attname in ('actor_id', 'subject_id'))),
  null::text[], 'no account id column without a foreign key');

-- Zed's data, everywhere it can be, as the app would create it ------------

select pg_temp.as_admin();
update public.profiles set avatar_path = 'de000000-0000-0000-0000-00000000000f/avatar.jpg'
  where id = 'de000000-0000-0000-0000-00000000000f';
insert into public.profile_details (user_id, bio) values ('de000000-0000-0000-0000-00000000000f', 'gone soon')
  on conflict (user_id) do update set bio = excluded.bio;
insert into public.follows (follower_id, followee_id) values
  ('de000000-0000-0000-0000-00000000000f', 'de000000-0000-0000-0000-00000000000a'),
  ('de000000-0000-0000-0000-00000000000a', 'de000000-0000-0000-0000-00000000000f');
insert into public.vehicles (id, owner_id, kind, make, model, year, visibility) values
  ('de100000-0000-0000-0000-00000000000f', 'de000000-0000-0000-0000-00000000000f', 'car', 'Mazda', 'MX-5', 1990, 'public'),
  ('de100000-0000-0000-0000-00000000000a', 'de000000-0000-0000-0000-00000000000a', 'car', 'Honda', 'S2000', 2004, 'public');
insert into public.vehicle_mods (vehicle_id, title) values ('de100000-0000-0000-0000-00000000000f', 'Coilovers');
insert into public.vehicle_photos (vehicle_id, storage_path) values
  ('de100000-0000-0000-0000-00000000000f', 'de000000-0000-0000-0000-00000000000f/de100000-0000-0000-0000-00000000000f/1.jpg');
insert into public.privacy_zones (user_id, label, lat, lon) values ('de000000-0000-0000-0000-00000000000f', 'Home', 51.5, -0.12);
insert into public.meets (id, host_id, title, starts_at, ends_at, venue_name, lat, lon, visibility) values
  ('de200000-0000-0000-0000-00000000000f', 'de000000-0000-0000-0000-00000000000f', 'Zed''s meet',
   now() + interval '1 day', now() + interval '1 day 2 hours', 'Car park', 51.5, -0.12, 'public');
insert into public.meet_rsvps (meet_id, user_id, status, show_me) values
  ('de200000-0000-0000-0000-00000000000f', 'de000000-0000-0000-0000-00000000000a', 'going', true);
insert into public.drives (id, owner_id, vehicle_id, started_at, ended_at, distance_m, moving_s, stopped_s, elapsed_s) values
  ('de300000-0000-0000-0000-00000000000f', 'de000000-0000-0000-0000-00000000000f', 'de100000-0000-0000-0000-00000000000f',
   now() - interval '1 hour', now() - interval '30 minutes', 20000, 1500, 300, 1800),
  ('de300000-0000-0000-0000-00000000000a', 'de000000-0000-0000-0000-00000000000a', 'de100000-0000-0000-0000-00000000000a',
   now() - interval '1 hour', now() - interval '30 minutes', 20000, 1500, 300, 1800);
-- Amy's drive was at Zed's meet: it stays hers, the link is cleared.
update public.drives set closed_course_meet_id = 'de200000-0000-0000-0000-00000000000f'
  where id = 'de300000-0000-0000-0000-00000000000a';
insert into public.drive_tracks (drive_id, owner_id, points) values
  ('de300000-0000-0000-0000-00000000000f', 'de000000-0000-0000-0000-00000000000f', '[[0, 51.5, -0.12, 0, 10, 5, 5, 1]]');
insert into public.drive_shared_routes (drive_id, segments) values ('de300000-0000-0000-0000-00000000000f', '[]');
insert into private.drive_cells (drive_id, cells) values ('de300000-0000-0000-0000-00000000000f', '{abc}')
  on conflict do nothing;
insert into private.drive_scores (drive_id, ranked_distance_m) values ('de300000-0000-0000-0000-00000000000f', 20000)
  on conflict do nothing;
insert into private.route_trim_extra (drive_id, start_m, end_m) values ('de300000-0000-0000-0000-00000000000f', 100, 100)
  on conflict do nothing;
insert into public.posts (id, author_id, caption, visibility) values
  ('de400000-0000-0000-0000-00000000000f', 'de000000-0000-0000-0000-00000000000f', 'Zed''s post', 'public'),
  ('de400000-0000-0000-0000-00000000000a', 'de000000-0000-0000-0000-00000000000a', 'Amy''s post', 'public');
insert into public.post_media (post_id, storage_path, media_type) values
  ('de400000-0000-0000-0000-00000000000f', 'de000000-0000-0000-0000-00000000000f/de400000-0000-0000-0000-00000000000f/0.jpg', 'image');
insert into public.likes (post_id, user_id) values
  ('de400000-0000-0000-0000-00000000000f', 'de000000-0000-0000-0000-00000000000a'),
  ('de400000-0000-0000-0000-00000000000a', 'de000000-0000-0000-0000-00000000000f');
insert into public.comments (post_id, author_id, body) values
  ('de400000-0000-0000-0000-00000000000f', 'de000000-0000-0000-0000-00000000000a', 'nice'),
  ('de400000-0000-0000-0000-00000000000a', 'de000000-0000-0000-0000-00000000000f', 'thanks');
insert into public.notifications (recipient_id, actor_id, kind) values
  ('de000000-0000-0000-0000-00000000000a', 'de000000-0000-0000-0000-00000000000f', 'follow'),
  ('de000000-0000-0000-0000-00000000000f', 'de000000-0000-0000-0000-00000000000a', 'follow');
insert into public.device_tokens (token, user_id, platform) values (repeat('ab', 32), 'de000000-0000-0000-0000-00000000000f', 'ios');
insert into public.entitlements (user_id, product_id, original_transaction_id, status, environment, signed_at) values
  ('de000000-0000-0000-0000-00000000000f', 'app.pullup.pro.yearly', 'de-zed-1', 'active', 'Production', now());
insert into private.function_calls (user_id, function_name) values ('de000000-0000-0000-0000-00000000000f', 'verify-subscription');
insert into private.identity_link_intents (user_id, provider) values ('de000000-0000-0000-0000-00000000000f', 'apple')
  on conflict do nothing;

-- A conversation with messages both ways, a reaction and a report each way.
select pg_temp.act_as('de000000-0000-0000-0000-00000000000f');
select public.start_conversation('de000000-0000-0000-0000-00000000000a') as conv \gset
insert into public.messages (id, conversation_id, sender_id, body) values
  ('de500000-0000-0000-0000-00000000000f', :'conv', 'de000000-0000-0000-0000-00000000000f', 'hi Amy');
select pg_temp.act_as('de000000-0000-0000-0000-00000000000a');
insert into public.messages (id, conversation_id, sender_id, body) values
  ('de500000-0000-0000-0000-00000000000a', :'conv', 'de000000-0000-0000-0000-00000000000a', 'hi Zed');
insert into public.message_reactions (message_id, user_id, emoji) values ('de500000-0000-0000-0000-00000000000f', 'de000000-0000-0000-0000-00000000000a', '👍');
select public.report_user('de000000-0000-0000-0000-00000000000f', 'spam', 'about Zed', 'de500000-0000-0000-0000-00000000000f');
select pg_temp.act_as('de000000-0000-0000-0000-00000000000f');
select public.report_user('de000000-0000-0000-0000-00000000000a', 'other', 'about Amy');

-- 3: before deletion, Zed can upload into their own folder ---------------
select lives_ok(
  $$ insert into storage.objects (bucket_id, name) values ('avatars', 'de000000-0000-0000-0000-00000000000f/before.jpg') $$,
  'uploads work while the account exists');

select pg_temp.as_admin();
create temp table zed_rows_before as
  select (select count(*) from public.messages where conversation_id = :'conv') as messages,
         (select count(*) from public.reports) as reports;
select ok((select messages = 2 and reports >= 2 from zed_rows_before), 'the fixture has messages and reports both ways');

-- 5–10: the deletion job delete-account records first -------------------
select pg_temp.act_as('de000000-0000-0000-0000-00000000000f');
select throws_ok($$ select * from public.account_deletion_begin('de000000-0000-0000-0000-00000000000f') $$,
  '42501', null, 'only the service role can start a deletion job');
select pg_temp.as_admin();
set local role service_role;
select is((select apple_token from public.account_deletion_begin('de000000-0000-0000-0000-00000000000f')), null,
  'a new job has no Apple token');
select public.account_deletion_failed('de000000-0000-0000-0000-00000000000f', 'storage: 503', 'apple-refresh', 'refresh_token');
select is((select apple_token from public.account_deletion_begin('de000000-0000-0000-0000-00000000000f')), 'apple-refresh',
  'a retry gets back the Apple token still to revoke');
select is((select count(*)::int from public.account_deletions_due() where user_id = 'de000000-0000-0000-0000-00000000000f'), 0,
  'a job just attempted isn''t due yet');
select pg_temp.as_admin();
update private.account_deletions set last_attempt_at = now() - interval '11 minutes'
  where user_id = 'de000000-0000-0000-0000-00000000000f';
set local role service_role;
select is((select attempts from public.account_deletions_due() where user_id = 'de000000-0000-0000-0000-00000000000f'), 2,
  'an unfinished job is due for the scheduled run after ten minutes');
select pg_temp.act_as('de000000-0000-0000-0000-00000000000f');
select throws_ok(
  $$ insert into storage.objects (bucket_id, name) values ('avatars', 'de000000-0000-0000-0000-00000000000f/during.jpg') $$,
  '42501', null, 'no uploads once deletion has started');
select pg_temp.as_admin();

-- The deletion delete-account performs.
delete from auth.users where id = 'de000000-0000-0000-0000-00000000000f';

-- 5: every column that references an account, in every table -------------
create or replace function pg_temp.rows_naming(uid uuid) returns text[] language plpgsql as $$
declare
  fk record;
  n bigint;
  found text[] := '{}';
begin
  for fk in
    select c.conrelid::regclass as tbl, a.attname as col
      from pg_constraint c join pg_attribute a on a.attrelid = c.conrelid and a.attnum = any(c.conkey)
     where c.contype = 'f' and c.confrelid in ('public.profiles'::regclass, 'auth.users'::regclass)
  loop
    execute format('select count(*) from %s where %I = $1', fk.tbl, fk.col) into n using uid;
    if n > 0 then found := found || format('%s.%s', fk.tbl, fk.col); end if;
  end loop;
  return found;
end $$;
select is(pg_temp.rows_naming('de000000-0000-0000-0000-00000000000f'), '{}'::text[],
  'no row in any table still names the deleted account');

-- 6–11: what hangs off Zed's rows went with them ----------------------------
select is((select count(*)::int from public.messages where conversation_id = :'conv'), 0,
  'the conversation and both people''s messages in it are gone');
select is((select count(*)::int from public.message_reactions where message_id = 'de500000-0000-0000-0000-00000000000f'), 0,
  'reactions to their messages are gone');
select is(
  (select count(*)::int from public.drive_tracks where drive_id = 'de300000-0000-0000-0000-00000000000f')
  + (select count(*)::int from public.drive_shared_routes where drive_id = 'de300000-0000-0000-0000-00000000000f')
  + (select count(*)::int from private.drive_cells where drive_id = 'de300000-0000-0000-0000-00000000000f')
  + (select count(*)::int from private.drive_scores where drive_id = 'de300000-0000-0000-0000-00000000000f')
  + (select count(*)::int from private.route_trim_extra where drive_id = 'de300000-0000-0000-0000-00000000000f'),
  0, 'GPS tracks, shared routes and derived drive data are gone');
select is(
  (select count(*)::int from public.vehicle_mods m where m.vehicle_id = 'de100000-0000-0000-0000-00000000000f')
  + (select count(*)::int from public.vehicle_photos p where p.vehicle_id = 'de100000-0000-0000-0000-00000000000f')
  + (select count(*)::int from public.post_media pm where pm.post_id = 'de400000-0000-0000-0000-00000000000f'),
  0, 'mods and photo/media rows are gone');
select is(
  (select count(*)::int from public.likes where post_id = 'de400000-0000-0000-0000-00000000000f')
  + (select count(*)::int from public.comments where post_id = 'de400000-0000-0000-0000-00000000000f')
  + (select count(*)::int from public.meet_rsvps where meet_id = 'de200000-0000-0000-0000-00000000000f'),
  0, 'other people''s likes, comments and RSVPs on their posts and meets are gone with them');
select is((select count(*)::int from storage.objects where name like 'de000000-0000-0000-0000-00000000000f/%'), 1,
  'Storage objects don''t cascade from the account, which is why delete-account removes them first');

-- 12–13: everyone else keeps their own things -------------------------------
select is(
  (select count(*)::int from public.drives where id = 'de300000-0000-0000-0000-00000000000a' and closed_course_meet_id is null)
  + (select count(*)::int from public.posts where id = 'de400000-0000-0000-0000-00000000000a')
  + (select count(*)::int from public.vehicles where id = 'de100000-0000-0000-0000-00000000000a')
  + (select count(*)::int from public.profiles where id = 'de000000-0000-0000-0000-00000000000a'),
  4, 'Amy''s profile, vehicle, post and drive stay (the drive just loses the meet link)');
select is((select count(*)::int from auth.identities where user_id = 'de000000-0000-0000-0000-00000000000f')
  + (select count(*)::int from private.account_deletions where user_id = 'de000000-0000-0000-0000-00000000000f'), 0,
  'the Sign in with Apple identity and the finished deletion job are gone');

-- 14: a token that outlives the account can't upload ----------------------
select pg_temp.act_as('de000000-0000-0000-0000-00000000000f');
select throws_ok(
  $$ insert into storage.objects (bucket_id, name) values ('avatars', 'de000000-0000-0000-0000-00000000000f/after.jpg') $$,
  '42501', null, 'an unexpired token of a deleted account can''t upload files no account owns');

select * from finish();
rollback;
