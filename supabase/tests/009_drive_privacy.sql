-- Security re-check G1 and G6 (docs/SECURITY_REPORT.md): a drive someone can
-- see must not give away its route through the exploration cells, and
-- nobody can read anyone else's drive-history setting.

begin;
create extension if not exists pgtap with schema extensions;
select plan(12);

insert into auth.users (id, email, raw_user_meta_data) values
  ('e9000000-0000-0000-0000-00000000000a', 'cells-ann@example.com', '{"username":"cells_ann"}'),
  ('e9000000-0000-0000-0000-00000000000b', 'cells-ben@example.com', '{"username":"cells_ben"}');

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

-- Ann and Ben are friends. Ann shares her drive history with friends, opts
-- into leaderboards and uploads one clean drive.
select pg_temp.act_as('e9000000-0000-0000-0000-00000000000a');
insert into public.follows (follower_id, followee_id) values (auth.uid(), 'e9000000-0000-0000-0000-00000000000b');
update public.privacy_settings set drive_history_visibility = 'friends', leaderboard_opt_in = true;
select pg_temp.act_as('e9000000-0000-0000-0000-00000000000b');
insert into public.follows (follower_id, followee_id) values (auth.uid(), 'e9000000-0000-0000-0000-00000000000a');
select pg_temp.act_as('e9000000-0000-0000-0000-00000000000a');
update public.follows set status = 'accepted' where followee_id = auth.uid();
select pg_temp.act_as('e9000000-0000-0000-0000-00000000000b');
update public.follows set status = 'accepted' where followee_id = auth.uid();

select pg_temp.act_as('e9000000-0000-0000-0000-00000000000a');
insert into public.drives (id, owner_id, started_at, ended_at, distance_m, moving_s, stopped_s, elapsed_s, top_speed_mps, visibility)
values ('e9100000-0000-0000-0000-000000000001', auth.uid(), now() - interval '1 hour', now() - interval '1 hour' + interval '199 seconds',
        4426, 199, 0, 199, 22.2, 'friends');
insert into public.drive_tracks (drive_id, owner_id, points)
select 'e9100000-0000-0000-0000-000000000001', auth.uid(),
  jsonb_agg(jsonb_build_array(i, 38.58 + i * 0.0002, -121.49, 20 + sin(i), 22.2, 5 + (i % 3), 4, 0.5) order by i)
from generate_series(0, 199) as i;

-- 1–4: G1 the cells are kept, but out of reach --------------------------------
select pg_temp.as_admin();
select ok((select cardinality(cells) > 0 from private.drive_cells where drive_id = 'e9100000-0000-0000-0000-000000000001'),
  'G1: validation still records the cells the drive covered');

select pg_temp.act_as('e9000000-0000-0000-0000-00000000000b');
select is((select count(*)::int from public.drives where id = 'e9100000-0000-0000-0000-000000000001'), 1,
  'G1: the friend can see the drive');
select is((select explored_cells from public.drives where id = 'e9100000-0000-0000-0000-000000000001'), '{}'::text[],
  'G1: but the drive row carries no cells');
select throws_ok($$ select * from private.drive_cells $$, '42501', null,
  'G1: and the cells table is closed to signed-in users');

-- 5: the owner can't rewrite them either ------------------------------------------
select pg_temp.act_as('e9000000-0000-0000-0000-00000000000a');
update public.drives set explored_cells = array['1:1', '2:2'], title = 'Renamed' where id = 'e9100000-0000-0000-0000-000000000001';
select pg_temp.as_admin();
select ok((select not cells @> array['1:1'] and cardinality(cells) > 2 from private.drive_cells where drive_id = 'e9100000-0000-0000-0000-000000000001'),
  'G1: a client update leaves the recorded cells alone');

-- 6: the exploration board still counts them -------------------------------------
select pg_temp.act_as('e9000000-0000-0000-0000-00000000000a');
select ok((select value > 0 from public.leaderboard('exploration', 'global', 'all_time') where is_me),
  'G1: the exploration leaderboard still ranks the drive');

-- 7–8: G6 drive-history setting --------------------------------------------------
select is(public.drive_history_ceiling('e9000000-0000-0000-0000-00000000000a'), 'friends'::public.visibility,
  'G6: the owner reads their own setting');
select pg_temp.act_as('e9000000-0000-0000-0000-00000000000b');
select is(public.drive_history_ceiling('e9000000-0000-0000-0000-00000000000a'), 'private'::public.visibility,
  'G6: anyone else gets nothing useful back');
select is(public.can_view_drive('e9100000-0000-0000-0000-000000000001'), true,
  'G6: shared drives still resolve for the friend');

-- 10: posting a drive still checks the owner's own setting ------------------------
select pg_temp.act_as('e9000000-0000-0000-0000-00000000000a');
select throws_ok(
  $$ insert into public.posts (author_id, kind, caption, drive_id, visibility)
     values (auth.uid(), 'drive', 'Sunday loop', 'e9100000-0000-0000-0000-000000000001', 'public') $$,
  '42501', null, 'G6: a post can''t be more visible than the drive history allows');

-- 11–12: rejected and deleted drives lose their cells --------------------------
select pg_temp.as_admin();
update public.drives set explored_cells = '{}' where id = 'e9100000-0000-0000-0000-000000000001';
select is((select count(*)::int from private.drive_cells where drive_id = 'e9100000-0000-0000-0000-000000000001'), 0,
  'G1: clearing the cells on the server removes them');
update public.drives set explored_cells = array['3:3'] where id = 'e9100000-0000-0000-0000-000000000001';
delete from public.drives where id = 'e9100000-0000-0000-0000-000000000001';
select is((select count(*)::int from private.drive_cells), 0, 'G1: deleting a drive deletes its cells');

select * from finish();
rollback;
