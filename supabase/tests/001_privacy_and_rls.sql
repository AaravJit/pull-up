-- Row-level security, privacy and validation behaviour. Run with
-- `supabase test db` (pgTAP). Each check acts as a real signed-in user by
-- switching to the `authenticated` role with a JWT subject.

begin;
create extension if not exists pgtap with schema extensions;
select plan(42);

-- Fixtures -----------------------------------------------------------------
insert into auth.users (id, email, raw_user_meta_data) values
  ('11111111-1111-1111-1111-111111111111', 'owner@example.com', '{"username":"owner"}'),
  ('22222222-2222-2222-2222-222222222222', 'friend@example.com', '{"username":"friend"}'),
  ('33333333-3333-3333-3333-333333333333', 'stranger@example.com', '{"username":"stranger"}'),
  ('44444444-4444-4444-4444-444444444444', 'host@example.com', '{"username":"host"}');

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

-- Synthetic 200-fix drive heading north at ~22 m/s with realistic noise.
create or replace function pg_temp.track(n int default 200, uniform boolean default false) returns jsonb language sql as $$
  select jsonb_agg(jsonb_build_array(
    i, 38.58 + i * 0.0002, -121.49, 20 + case when uniform then 0 else sin(i) end, 22.2,
    case when uniform then 5 else 5 + (i % 3) end, 4, 0.5) order by i)
  from generate_series(0, n - 1) as i;
$$;

-- Owner and friend follow each other; stranger follows owner one way.
select pg_temp.act_as('11111111-1111-1111-1111-111111111111');
insert into public.follows (follower_id, followee_id) values ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222');
select pg_temp.act_as('22222222-2222-2222-2222-222222222222');
insert into public.follows (follower_id, followee_id) values ('22222222-2222-2222-2222-222222222222', '11111111-1111-1111-1111-111111111111');
select pg_temp.act_as('33333333-3333-3333-3333-333333333333');
insert into public.follows (follower_id, followee_id) values ('33333333-3333-3333-3333-333333333333', '11111111-1111-1111-1111-111111111111');

-- 1–3: defaults are private ---------------------------------------------------
select pg_temp.act_as('11111111-1111-1111-1111-111111111111');
select is((select drive_history_visibility::text from public.privacy_settings), 'private', 'drive history defaults to private');
select is((select leaderboard_opt_in from public.privacy_settings), false, 'leaderboards are opt-in');
select is((select count(*)::int from public.privacy_settings), 1, 'privacy settings are visible only to their owner');

-- 4–9: vehicle visibility -------------------------------------------------------
insert into public.vehicles (id, owner_id, kind, make, model, year, visibility) values
  ('a0000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'car', 'Mazda', 'RX-7', 1994, 'public'),
  ('a0000000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'car', 'BMW', '320i', 2014, 'friends'),
  ('a0000000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111', 'motorcycle', 'Suzuki', 'GSX-R750', 2001, 'private');

select pg_temp.act_as('22222222-2222-2222-2222-222222222222');
select is((select count(*)::int from public.vehicles where owner_id = '11111111-1111-1111-1111-111111111111'), 2, 'friend sees public and friends-only vehicles');
select is((select count(*)::int from public.vehicles where id = 'a0000000-0000-0000-0000-000000000003'), 0, 'friend cannot see a private vehicle');

select pg_temp.act_as('33333333-3333-3333-3333-333333333333');
select is((select count(*)::int from public.vehicles where owner_id = '11111111-1111-1111-1111-111111111111'), 1, 'one-way follower sees only public vehicles');
update public.vehicles set make = 'Hacked' where id = 'a0000000-0000-0000-0000-000000000001';
select pg_temp.as_admin();
select is((select make from public.vehicles where id = 'a0000000-0000-0000-0000-000000000001'), 'Mazda', 'non-owner cannot edit a vehicle');

select pg_temp.act_as('33333333-3333-3333-3333-333333333333');
select throws_ok(
  $$ insert into public.vehicles (owner_id, kind, make, model, year) values ('11111111-1111-1111-1111-111111111111', 'car', 'X', 'Y', 2020) $$,
  '42501', null, 'cannot create a vehicle in someone else''s garage');
select is((select count(*)::int from public.vehicle_photos where vehicle_id = 'a0000000-0000-0000-0000-000000000003'), 0, 'private vehicle photos are unreachable');

-- 10–17: drives, tracks and validation ---------------------------------------
select pg_temp.act_as('11111111-1111-1111-1111-111111111111');
insert into public.drives (id, owner_id, vehicle_id, started_at, ended_at, distance_m, moving_s, stopped_s, elapsed_s, top_speed_mps, visibility, validation_status)
values ('d0000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'a0000000-0000-0000-0000-000000000001',
        now() - interval '1 hour', now() - interval '1 hour' + interval '199 seconds', 4426, 199, 0, 199, 22.2, 'public', 'validated');
select is((select validation_status from public.drives where id = 'd0000000-0000-0000-0000-000000000001'), 'pending', 'client cannot self-validate a drive');
select throws_ok(
  $$ insert into public.drives (owner_id, vehicle_id, started_at, ended_at, distance_m, moving_s, stopped_s, elapsed_s)
     values ('11111111-1111-1111-1111-111111111111', 'a0000000-0000-0000-0000-00000000dead', now() - interval '1 hour', now(), 1, 1, 0, 1) $$,
  '42501', null, 'drive must use one of your own vehicles');

insert into public.drive_tracks (drive_id, owner_id, points) values ('d0000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', pg_temp.track());
select is((select validation_status from public.drives where id = 'd0000000-0000-0000-0000-000000000001'), 'validated', 'clean track validates');
select ok((select abs(server_distance_m - 4426) < 30 from public.drives where id = 'd0000000-0000-0000-0000-000000000001'), 'server recomputes distance from the track');

select pg_temp.act_as('22222222-2222-2222-2222-222222222222');
select is((select count(*)::int from public.drives where id = 'd0000000-0000-0000-0000-000000000001'), 0, 'public drive stays hidden while the owner''s history ceiling is private');
select pg_temp.act_as('11111111-1111-1111-1111-111111111111');
update public.privacy_settings set drive_history_visibility = 'friends';
select pg_temp.act_as('22222222-2222-2222-2222-222222222222');
select is((select count(*)::int from public.drives where id = 'd0000000-0000-0000-0000-000000000001'), 1, 'friend sees the drive once the ceiling allows friends');
select is((select count(*)::int from public.drive_tracks), 0, 'raw tracks are never visible to anyone but the owner');
select pg_temp.act_as('33333333-3333-3333-3333-333333333333');
select is((select count(*)::int from public.drives where id = 'd0000000-0000-0000-0000-000000000001'), 0, 'stranger still cannot see a friends-capped drive');

-- 18–20: spoofing heuristics -------------------------------------------------
select pg_temp.act_as('11111111-1111-1111-1111-111111111111');
insert into public.drives (id, owner_id, started_at, ended_at, distance_m, moving_s, stopped_s, elapsed_s, top_speed_mps)
values ('d0000000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111',
        now() - interval '3 hours', now() - interval '3 hours' + interval '199 seconds', 4426, 199, 0, 199, 22.2);
insert into public.drive_tracks (drive_id, owner_id, points) values ('d0000000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', pg_temp.track(200, true));
select is((select validation_status from public.drives where id = 'd0000000-0000-0000-0000-000000000002'), 'flagged', 'perfectly uniform accuracy and altitude are flagged');

insert into public.drives (id, owner_id, started_at, ended_at, distance_m, moving_s, stopped_s, elapsed_s, top_speed_mps)
values ('d0000000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111',
        now() - interval '5 hours', now() - interval '5 hours' + interval '199 seconds', 40000, 199, 0, 199, 80);
insert into public.drive_tracks (drive_id, owner_id, points) values ('d0000000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111', pg_temp.track());
select is((select validation_status from public.drives where id = 'd0000000-0000-0000-0000-000000000003'), 'rejected', 'inflated distance and top speed are rejected');
select ok((select validation_notes @> array['distance_mismatch', 'top_speed_not_in_track'] from public.drives where id = 'd0000000-0000-0000-0000-000000000003'), 'rejection explains why');

-- 21–25: route sharing and redaction -----------------------------------------
select throws_ok($$ select public.share_drive_route('d0000000-0000-0000-0000-000000000001') $$, '42501', null, 'sharing refuses while route sharing is off');
update public.privacy_settings set allow_route_sharing = true;
insert into public.privacy_zones (user_id, label, lat, lon, radius_m) values ('11111111-1111-1111-1111-111111111111', 'Home', 38.60, -121.49, 200);
select lives_ok($$ select public.share_drive_route('d0000000-0000-0000-0000-000000000001') $$, 'owner can share once enabled');
select ok(
  (select bool_and(public.haversine_m(38.60, -121.49, (pt ->> 0)::float8, (pt ->> 1)::float8) > 350)
     from public.drive_shared_routes r, jsonb_array_elements(r.segments) seg, jsonb_array_elements(seg) pt),
  'no shared point falls within the privacy zone plus margin');
select ok(
  (select min(public.haversine_m(38.58, -121.49, (pt ->> 0)::float8, (pt ->> 1)::float8)) >= 390
     from public.drive_shared_routes r, jsonb_array_elements(r.segments) seg, jsonb_array_elements(seg) pt),
  'shared route never reaches within the trim distance of the true start');
select is((select jsonb_array_length(segments) from public.drive_shared_routes), 2, 'zone splits the route into two segments');

select pg_temp.act_as('33333333-3333-3333-3333-333333333333');
select is((select count(*)::int from public.drive_shared_routes), 0, 'shared route follows the drive''s visibility');
select throws_ok($$ select public.share_drive_route('d0000000-0000-0000-0000-000000000001') $$, '42501', null, 'only the owner can share');

select pg_temp.act_as('11111111-1111-1111-1111-111111111111');
update public.privacy_settings set allow_route_sharing = false;
select is((select count(*)::int from public.drive_shared_routes), 0, 'turning sharing off withdraws shared routes');

-- 29–32: posts cannot out-share their attachments ----------------------------
select throws_ok(
  $$ insert into public.posts (author_id, kind, vehicle_id, visibility) values ('11111111-1111-1111-1111-111111111111', 'build', 'a0000000-0000-0000-0000-000000000002', 'public') $$,
  '42501', null, 'a public post cannot show a friends-only vehicle');
insert into public.posts (id, author_id, kind, vehicle_id, visibility, caption)
values ('b0000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'build', 'a0000000-0000-0000-0000-000000000002', 'friends', 'Coilovers in');
select pg_temp.act_as('22222222-2222-2222-2222-222222222222');
select is((select count(*)::int from public.posts where id = 'b0000000-0000-0000-0000-000000000001'), 1, 'friend sees the friends-only build post');
insert into public.likes (post_id, user_id) values ('b0000000-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222');
select pg_temp.act_as('33333333-3333-3333-3333-333333333333');
select is((select count(*)::int from public.posts where id = 'b0000000-0000-0000-0000-000000000001'), 0, 'stranger cannot see it');
select throws_ok(
  $$ insert into public.likes (post_id, user_id) values ('b0000000-0000-0000-0000-000000000001', '33333333-3333-3333-3333-333333333333') $$,
  '42501', null, 'cannot like a post you cannot see');

-- 33–37: meets and attendee privacy ------------------------------------------
select pg_temp.act_as('44444444-4444-4444-4444-444444444444');
insert into public.meets (id, host_id, title, kind, starts_at, ends_at, venue_name, lat, lon, capacity)
values ('e0000000-0000-0000-0000-000000000001', '44444444-4444-4444-4444-444444444444', 'Sac Nights', 'meet',
        now() + interval '1 day', now() + interval '1 day 3 hours', 'Sutter Lot', 38.57, -121.48, 2);

select pg_temp.act_as('11111111-1111-1111-1111-111111111111');
insert into public.meet_rsvps (meet_id, user_id, status) values ('e0000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'going');
select is((select show_me from public.meet_rsvps where user_id = '11111111-1111-1111-1111-111111111111'), false, 'attendance is hidden by default');

select pg_temp.act_as('22222222-2222-2222-2222-222222222222');
insert into public.meet_rsvps (meet_id, user_id, status, show_me) values ('e0000000-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'going', true);
select is((select count(*)::int from public.meet_attendees('e0000000-0000-0000-0000-000000000001')), 1, 'fellow attendee sees only themselves when others hide');

select pg_temp.act_as('11111111-1111-1111-1111-111111111111');
select is((select count(*)::int from public.meet_attendees('e0000000-0000-0000-0000-000000000001')), 2, 'attendee sees opted-in attendees');

select pg_temp.act_as('33333333-3333-3333-3333-333333333333');
select is((select count(*)::int from public.meet_attendees('e0000000-0000-0000-0000-000000000001')), 0, 'non-attendee sees no attendees');
select throws_ok(
  $$ insert into public.meet_rsvps (meet_id, user_id, status) values ('e0000000-0000-0000-0000-000000000001', '33333333-3333-3333-3333-333333333333', 'going') $$,
  '23514', null, 'capacity is enforced');

-- 38–40: leaderboards ---------------------------------------------------------
select pg_temp.act_as('11111111-1111-1111-1111-111111111111');
select is((select count(*)::int from public.leaderboard('distance', 'global', 'all_time')), 0, 'no entries while nobody has opted in');
update public.privacy_settings set leaderboard_opt_in = true, performance_leaderboard_opt_in = true;
select ok((select value > 4000 from public.leaderboard('distance', 'global', 'all_time') where is_me), 'opted-in validated distance is ranked');
select is((select count(*)::int from public.leaderboard('top_speed', 'global', 'all_time')), 0, 'road drives never reach performance boards');

-- 41–42: blocking and anonymous access ---------------------------------------
select pg_temp.act_as('11111111-1111-1111-1111-111111111111');
insert into public.blocks (blocker_id, blocked_id) values ('11111111-1111-1111-1111-111111111111', '33333333-3333-3333-3333-333333333333');
select pg_temp.act_as('33333333-3333-3333-3333-333333333333');
select is((select count(*)::int from public.vehicles where owner_id = '11111111-1111-1111-1111-111111111111'), 0, 'blocked user sees nothing of the blocker');

select pg_temp.as_admin();
set local role anon;
select throws_ok($$ select count(*) from public.profiles $$, '42501', null, 'anonymous clients read nothing');

select * from finish();
rollback;
