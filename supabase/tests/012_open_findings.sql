-- Security re-check, the findings 20261018000800 closes (docs/SECURITY_REPORT.md):
-- row-argument counts, G2 route trim, G5 storage quota, G7 orphaned DM
-- photos, G13 rls_auto_enable.

begin;
create extension if not exists pgtap with schema extensions;
select plan(22);

insert into auth.users (id, email, raw_user_meta_data) values
  ('ec000000-0000-0000-0000-00000000000a', 'open-ann@example.com', '{"username":"open_ann"}'),
  ('ec000000-0000-0000-0000-00000000000b', 'open-ben@example.com', '{"username":"open_ben"}'),
  ('ec000000-0000-0000-0000-00000000000c', 'open-cat@example.com', '{"username":"open_cat"}');

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

create or replace function pg_temp.as_service() returns void language plpgsql as $$
begin
  perform set_config('role', 'service_role', true);
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  perform set_config('request.jwt.claim.sub', '', true);
end $$;

-- Ann has a private post and a friends-only meet, both with activity. Ben
-- is a stranger to her.
select pg_temp.act_as('ec000000-0000-0000-0000-00000000000a');
insert into public.posts (id, author_id, kind, visibility, caption)
values ('ec100000-0000-0000-0000-000000000001', auth.uid(), 'moment', 'private', 'Just me');
insert into public.likes (post_id, user_id) values ('ec100000-0000-0000-0000-000000000001', auth.uid());
insert into public.comments (post_id, author_id, body) values ('ec100000-0000-0000-0000-000000000001', auth.uid(), 'Note to self');
insert into public.meets (id, host_id, title, kind, starts_at, ends_at, venue_name, lat, lon, visibility)
values ('ec200000-0000-0000-0000-000000000001', auth.uid(), 'Quiet meet', 'meet',
        now() + interval '1 day', now() + interval '1 day 2 hours', 'Back lot', 38.57, -121.48, 'friends');
insert into public.meet_rsvps (meet_id, user_id, status, show_me) values ('ec200000-0000-0000-0000-000000000001', auth.uid(), 'going', false);
select pg_temp.as_admin();
insert into public.meet_rsvps (meet_id, user_id, status, show_me) values ('ec200000-0000-0000-0000-000000000001', 'ec000000-0000-0000-0000-00000000000c', 'interested', false);
select pg_temp.act_as('ec000000-0000-0000-0000-00000000000a');

-- 1–6: counts called with a made-up row, the way an RPC passes one ----------------
select is(public.like_count(jsonb_populate_record(null::public.posts, '{"id":"ec100000-0000-0000-0000-000000000001"}')), 1,
  'the author still sees the like count of her own post');
select pg_temp.act_as('ec000000-0000-0000-0000-00000000000b');
select is(public.like_count(jsonb_populate_record(null::public.posts, '{"id":"ec100000-0000-0000-0000-000000000001"}')), 0,
  'like_count tells a stranger nothing about a post they can''t see');
select is(public.comment_count(jsonb_populate_record(null::public.posts, '{"id":"ec100000-0000-0000-0000-000000000001"}')), 0,
  'comment_count tells a stranger nothing about a post they can''t see');
select is(public.going_count(jsonb_populate_record(null::public.meets, '{"id":"ec200000-0000-0000-0000-000000000001"}')), 0,
  'going_count tells a stranger nothing about a meet they can''t see');
select is(public.interested_count(jsonb_populate_record(null::public.meets, '{"id":"ec200000-0000-0000-0000-000000000001"}')), 0,
  'interested_count tells a stranger nothing about a meet they can''t see');
select pg_temp.act_as('ec000000-0000-0000-0000-00000000000a');
select is((select public.going_count(m) from public.meets m where m.id = 'ec200000-0000-0000-0000-000000000001'), 1,
  'the host still sees who is going');

-- 7–11: G2 the extra trim is drawn once per drive ----------------------------------
update public.privacy_settings set allow_route_sharing = true;
insert into public.drives (id, owner_id, started_at, ended_at, distance_m, moving_s, stopped_s, elapsed_s, top_speed_mps, visibility)
values ('ec300000-0000-0000-0000-000000000001', auth.uid(), now() - interval '1 hour', now() - interval '1 hour' + interval '199 seconds',
        4426, 199, 0, 199, 22.2, 'friends');
insert into public.drive_tracks (drive_id, owner_id, points)
select 'ec300000-0000-0000-0000-000000000001', auth.uid(),
  jsonb_agg(jsonb_build_array(i, 38.58 + i * 0.0002, -121.49, 20 + sin(i), 22.2, 5 + (i % 3), 4, 0.5) order by i)
from generate_series(0, 199) as i;

create temporary table routes (n int primary key, segments jsonb) on commit drop;
grant all on routes to authenticated;
insert into routes values (1, public.share_drive_route('ec300000-0000-0000-0000-000000000001'));
select public.unshare_drive_route('ec300000-0000-0000-0000-000000000001');
insert into routes select n, public.share_drive_route('ec300000-0000-0000-0000-000000000001') from generate_series(2, 6) n;
select is((select count(distinct segments)::int from routes), 1,
  'G2: sharing the same drive again gives exactly the same trimmed route');
-- A privacy zone far from the route rebuilds it without hiding anything.
insert into public.privacy_zones (user_id, lat, lon, radius_m) values (auth.uid(), 10, 10, 100);
select is((select segments from public.drive_shared_routes where drive_id = 'ec300000-0000-0000-0000-000000000001'),
  (select segments from routes where n = 1), 'G2: a rebuild after a privacy zone change keeps the same trim');

select pg_temp.as_admin();
select ok((select start_m >= 0 and start_m < 250 and end_m >= 0 and end_m < 250 from private.route_trim_extra
           where drive_id = 'ec300000-0000-0000-0000-000000000001'), 'G2: the stored extra is within 0–250 m');
select pg_temp.act_as('ec000000-0000-0000-0000-00000000000a');
select throws_ok($$ select * from private.route_trim_extra $$, '42501', null, 'G2: the stored extra is out of the owner''s reach too');
delete from public.drives where id = 'ec300000-0000-0000-0000-000000000001';
select pg_temp.as_admin();
select is((select count(*)::int from private.route_trim_extra where drive_id = 'ec300000-0000-0000-0000-000000000001'), 0,
  'G2: deleting the drive deletes its stored extra');

-- 12–16: G5 storage quota -------------------------------------------------------------
-- Cat has 2 GB minus one byte stored: one more file is fine, the next isn't.
insert into storage.objects (bucket_id, name, metadata) values
  ('post-media', 'ec000000-0000-0000-0000-00000000000c/big.mp4', '{"size": 2147483647}');
select pg_temp.act_as('ec000000-0000-0000-0000-00000000000c');
select lives_ok($$ insert into storage.objects (bucket_id, name, metadata) values ('avatars', 'ec000000-0000-0000-0000-00000000000c/me.jpg', '{"size": 1}') $$,
  'G5: an account under its quota can upload');
select throws_ok($$ insert into storage.objects (bucket_id, name) values ('vehicle-media', 'ec000000-0000-0000-0000-00000000000c/car.jpg') $$,
  '42501', null, 'G5: an account at 2 GB can''t upload more');
select pg_temp.act_as('ec000000-0000-0000-0000-00000000000b');
select lives_ok($$ insert into storage.objects (bucket_id, name) values ('avatars', 'ec000000-0000-0000-0000-00000000000b/me.jpg') $$,
  'G5: other accounts aren''t affected');
-- Ben has 5,000 tiny files: no more.
select pg_temp.as_admin();
insert into storage.objects (bucket_id, name, metadata)
select 'vehicle-media', 'ec000000-0000-0000-0000-00000000000b/f' || n || '.jpg', '{"size": 10}' from generate_series(1, 4999) n;
select pg_temp.act_as('ec000000-0000-0000-0000-00000000000b');
select throws_ok($$ insert into storage.objects (bucket_id, name) values ('avatars', 'ec000000-0000-0000-0000-00000000000b/me-2.jpg') $$,
  '42501', null, 'G5: an account with 5,000 files can''t upload more');
-- DM photos count towards the quota as well.
select pg_temp.act_as('ec000000-0000-0000-0000-00000000000c');
create temporary table convs (id uuid) on commit drop;
grant all on convs to authenticated;
insert into convs values (public.start_conversation('ec000000-0000-0000-0000-00000000000a'));
select throws_ok(format($$ insert into storage.objects (bucket_id, name) values ('dm-media', '%s/ec000000-0000-0000-0000-00000000000c/x.jpg') $$,
  (select id from convs)), '42501', null, 'G5: the quota covers DM photos too');

-- 17–21: G7 orphaned DM photos ----------------------------------------------------------
select pg_temp.as_admin();
delete from storage.objects where name like 'ec000000-0000-0000-0000-00000000000c/%';
insert into storage.objects (bucket_id, name, created_at)
select 'dm-media', c.id || '/ec000000-0000-0000-0000-00000000000c/' || f, now() - age
from convs c, (values ('sent.jpg', interval '2 days'), ('abandoned.jpg', interval '2 days'), ('fresh.jpg', interval '1 hour')) v(f, age);
select pg_temp.act_as('ec000000-0000-0000-0000-00000000000c');
insert into public.messages (conversation_id, sender_id, media_path)
select id, auth.uid(), id || '/ec000000-0000-0000-0000-00000000000c/sent.jpg' from convs;
select throws_ok($$ select * from public.dm_orphaned_media() $$, '42501', null, 'G7: signed-in users can''t list orphaned photos');

select pg_temp.as_service();
create temporary table orphans on commit drop as select name from public.dm_orphaned_media();
select is((select count(*)::int from orphans where name like '%/abandoned.jpg'), 1, 'G7: a photo that was never sent is listed');
select is((select count(*)::int from orphans where name like '%/sent.jpg'), 0, 'G7: a photo in a message is kept');
select is((select count(*)::int from orphans where name like '%/fresh.jpg'), 0, 'G7: a photo uploaded in the last day is kept (it may still be sent)');
select pg_temp.act_as('ec000000-0000-0000-0000-00000000000c');
select public.unsend_message((select id from public.messages where sender_id = auth.uid()));
select pg_temp.as_service();
select is((select count(*)::int from public.dm_orphaned_media() where name like '%/sent.jpg'), 1,
  'G7: once its message is unsent, the photo is listed too');

-- 22: G13 -------------------------------------------------------------------------------
select pg_temp.as_admin();
select ok(to_regprocedure('public.rls_auto_enable()') is null
          or not has_function_privilege('authenticated', 'public.rls_auto_enable()', 'execute'),
  'G13: signed-in users can''t call rls_auto_enable (only exists on hosted projects)');

select * from finish();
rollback;
