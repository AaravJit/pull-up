-- Drive distance bounds (20261020000200): the app's Doppler distance is
-- accepted between the noise-free lower bound and the raw sum of segments.

begin;
create extension if not exists pgtap with schema extensions;
select plan(13);

insert into auth.users (id, email, raw_user_meta_data) values
  ('db000000-0000-0000-0000-00000000000a', 'bounds-ann@example.com', '{"username":"bounds_ann"}');

create or replace function pg_temp.act_as(uid uuid) returns void language plpgsql as $$
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', uid::text, true);
end $$;

-- 300 fixes crawling north at 3 m/s (~898 m) with ±6 m sideways GPS
-- jitter and 8–10 m accuracy. The raw sum of segments is ~3750 m. With a
-- jump, fixes from #150 on are 556 m further north and `jump_s` later:
-- where the app relocked and added no distance. `wide` claims ~5 km
-- accuracy on every fix. `hops` adds an 89 m step in one second every
-- 50 fixes: under the 120 m/s teleport limit, but far more than 3 m/s
-- allows, so each is a Doppler relock.
create or replace function pg_temp.crawl(jump boolean default false, jump_s int default 0, wide boolean default false,
                                         hops boolean default false)
returns jsonb language sql as $$
  select jsonb_agg(jsonb_build_array(
    i + case when jump and i >= 150 then jump_s else 0 end,
    38.58 + i * 0.000027 + case when jump and i >= 150 then 0.005 else 0 end
      + case when hops then (i / 50) * 0.0008 else 0 end,
    -121.49 + case when i % 2 = 1 then 0.00007 else -0.00007 end,
    20 + sin(i), 3, case when wide then 5000 else 8 end + (i % 3), 4, 0.5) order by i)
  from generate_series(0, 299) as i;
$$;

create or replace function pg_temp.drive(p_id uuid, hours_ago int, distance double precision,
                                         jump boolean default false, jump_s int default 0, wide boolean default false,
                                         hops boolean default false)
returns void language sql as $$
  insert into public.drives (id, owner_id, started_at, ended_at, distance_m, moving_s, stopped_s, elapsed_s, top_speed_mps)
  values (p_id, auth.uid(), now() - make_interval(hours => hours_ago),
          now() - make_interval(hours => hours_ago) + interval '299 seconds', distance, 299, 0, 299, 3);
  insert into public.drive_tracks (drive_id, owner_id, points) values (p_id, auth.uid(), pg_temp.crawl(jump, jump_s, wide, hops));
$$;

select pg_temp.act_as('db000000-0000-0000-0000-00000000000a');

-- 1–2: the app's true distance, far below the noisy raw sum, validates.
select pg_temp.drive('db100000-0000-0000-0000-000000000001', 2, 898);
select is((select validation_status from public.drives where id = 'db100000-0000-0000-0000-000000000001'), 'validated',
  'a slow drive whose Doppler distance is well below the raw sum validates');
select ok((select server_distance_m > 3500 from public.drives where id = 'db100000-0000-0000-0000-000000000001'),
  'server_distance_m is still the raw sum');

-- 3–4: a figure far under the lower bound is still rejected.
select pg_temp.drive('db100000-0000-0000-0000-000000000002', 4, 100);
select is((select validation_status from public.drives where id = 'db100000-0000-0000-0000-000000000002'), 'rejected',
  'a distance far below the lower bound is rejected');
select ok((select validation_notes @> array['distance_mismatch'] from public.drives where id = 'db100000-0000-0000-0000-000000000002'),
  'the rejection names distance_mismatch');

-- 5–6: a figure just over the raw sum drifts, as before.
select pg_temp.drive('db100000-0000-0000-0000-000000000003', 6, 4100);
select is((select validation_status from public.drives where id = 'db100000-0000-0000-0000-000000000003'), 'flagged',
  'a distance just above the raw sum is flagged');
select ok((select validation_notes = array['distance_drift'] from public.drives where id = 'db100000-0000-0000-0000-000000000003'),
  'the flag names distance_drift only');

-- 7–9: a relock jump adds nothing in the app, so the lower bound skips it
-- too, whether it is a teleport (556 m in 1 s) or just further than the
-- Doppler speed allows (556 m in 5 s at 3 m/s).
select pg_temp.drive('db100000-0000-0000-0000-000000000004', 8, 898, true, 0);
select is((select validation_status from public.drives where id = 'db100000-0000-0000-0000-000000000004'), 'validated',
  'a teleport the app relocked across does not raise the lower bound');
select pg_temp.drive('db100000-0000-0000-0000-000000000005', 10, 898, true, 4);
select is((select validation_status from public.drives where id = 'db100000-0000-0000-0000-000000000005'), 'validated',
  'a Doppler-implausible jump the app relocked across does not raise the lower bound');
select ok((select server_distance_m < 3800 from public.drives where id = 'db100000-0000-0000-0000-000000000005'),
  'nor is it counted in server_distance_m');

-- 10–11: inflated accuracy in the upload can't erase the lower bound.
select pg_temp.drive('db100000-0000-0000-0000-000000000006', 12, 0, false, 0, true);
select is((select validation_status from public.drives where id = 'db100000-0000-0000-0000-000000000006'), 'rejected',
  'a zero distance with ~5 km claimed accuracy is still rejected');
select ok((select validation_notes @> array['distance_mismatch'] from public.drives where id = 'db100000-0000-0000-0000-000000000006'),
  'accuracy is capped at the app''s 35 m limit for the bound');

-- 12–13: Doppler relocks count as position jumps like teleports do, so
-- five of them flag the drive.
select pg_temp.drive('db100000-0000-0000-0000-000000000007', 14, 898, hops => true);
select is((select validation_status from public.drives where id = 'db100000-0000-0000-0000-000000000007'), 'flagged',
  'a drive with five Doppler relocks is flagged');
select ok((select validation_notes = array['position_jumps'] from public.drives where id = 'db100000-0000-0000-0000-000000000007'),
  'the flag names position_jumps only');

select * from finish();
rollback;
