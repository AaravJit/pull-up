-- Drive distance bounds (20261020000200): the app's Doppler distance is
-- accepted between the noise-free lower bound and the raw sum of segments.

begin;
create extension if not exists pgtap with schema extensions;
select plan(6);

insert into auth.users (id, email, raw_user_meta_data) values
  ('db000000-0000-0000-0000-00000000000a', 'bounds-ann@example.com', '{"username":"bounds_ann"}');

create or replace function pg_temp.act_as(uid uuid) returns void language plpgsql as $$
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', uid::text, true);
end $$;

-- 300 fixes crawling north at 3 m/s (~898 m) with ±6 m sideways GPS
-- jitter and 8–10 m accuracy. The raw sum of segments is ~3750 m.
create or replace function pg_temp.crawl() returns jsonb language sql as $$
  select jsonb_agg(jsonb_build_array(
    i, 38.58 + i * 0.000027, -121.49 + case when i % 2 = 1 then 0.00007 else -0.00007 end,
    20 + sin(i), 3, 8 + (i % 3), 4, 0.5) order by i)
  from generate_series(0, 299) as i;
$$;

create or replace function pg_temp.drive(p_id uuid, hours_ago int, distance double precision) returns void language sql as $$
  insert into public.drives (id, owner_id, started_at, ended_at, distance_m, moving_s, stopped_s, elapsed_s, top_speed_mps)
  values (p_id, auth.uid(), now() - make_interval(hours => hours_ago),
          now() - make_interval(hours => hours_ago) + interval '299 seconds', distance, 299, 0, 299, 3);
  insert into public.drive_tracks (drive_id, owner_id, points) values (p_id, auth.uid(), pg_temp.crawl());
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

select * from finish();
rollback;
