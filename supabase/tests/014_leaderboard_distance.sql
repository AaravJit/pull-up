-- Leaderboard distance (20261020000300): boards rank the smaller of a
-- drive's anchored distance and its coverage, so parked jitter and going
-- back and forth don't add up, while ordinary drives count in full.

begin;
create extension if not exists pgtap with schema extensions;
select plan(17);

insert into auth.users (id, email, raw_user_meta_data) values
  ('dc000000-0000-0000-0000-00000000000a', 'ranked-ann@example.com', '{"username":"ranked_ann"}');
-- These accounts confirmed the minimum age and accepted the current terms
-- (20261025000400); 040/041 test what happens without that.
insert into public.terms_acceptances (user_id, version)
select p.id, v.version from public.profiles p, public.terms_versions v where v.is_current on conflict do nothing;
insert into private.age_checks (user_id, meets_minimum, minimum_age, method)
select id, true, 13, 'self_declared' from public.profiles on conflict do nothing;

create or replace function pg_temp.act_as(uid uuid) returns void language plpgsql as $$
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', uid::text, true);
end $$;

-- One fix a second at `north(i)` metres north of the start, with a few
-- metres of deterministic GPS jitter, varied accuracy and altitude.
create or replace function pg_temp.track(n int, speed double precision, shape text, jitter double precision, hacc double precision)
returns jsonb language sql as $$
  select jsonb_agg(jsonb_build_array(
    i,
    38.58 + (case shape
               when 'straight' then i * speed
               when 'parked' then 0
               when 'oscillate' then case when (i / 30) % 2 = 0 then i % 30 else 30 - i % 30 end * speed
               when 'out_and_back' then least(i, n - 1 - i) * speed
             end + jitter * sin(i * 1.3)) / 111195.0,
    -121.49 + jitter * cos(i * 0.7) / 86899.0,
    20 + sin(i), speed, hacc + (i % 3), 4, 0.5) order by i)
  from generate_series(0, n - 1) as i;
$$;

create or replace function pg_temp.drive(p_id uuid, hours_ago int, distance double precision, top double precision, pts jsonb)
returns void language sql as $$
  insert into public.drives (id, owner_id, started_at, ended_at, distance_m, moving_s, stopped_s, elapsed_s, top_speed_mps)
  values (p_id, auth.uid(), now() - make_interval(hours => hours_ago),
          now() - make_interval(hours => hours_ago) + make_interval(secs => jsonb_array_length(pts) - 1),
          distance, jsonb_array_length(pts) - 1, 0, jsonb_array_length(pts) - 1, top);
  insert into public.drive_tracks (drive_id, owner_id, points) values (p_id, auth.uid(), pts);
$$;

create or replace function pg_temp.ranked(p_id uuid) returns double precision language sql as $$
  select ranked_distance_m from private.drive_scores where drive_id = p_id;
$$;

select pg_temp.act_as('dc000000-0000-0000-0000-00000000000a');
-- 3 km north at 25 m/s.
select pg_temp.drive('dc100000-0000-0000-0000-000000000001', 2, 3000, 25, pg_temp.track(121, 25, 'straight', 2, 5));
-- Parked for 30 minutes, recording 8 m of jitter; the app reports 0 m.
select pg_temp.drive('dc100000-0000-0000-0000-000000000002', 4, 0, 0, pg_temp.track(1801, 0, 'parked', 8, 8));
-- 50 passes over a 300 m strip at 10 m/s.
select pg_temp.drive('dc100000-0000-0000-0000-000000000003', 6, 15000, 10, pg_temp.track(1501, 10, 'oscillate', 2, 5));
-- 1.5 km out and 1.5 km back at 25 m/s.
select pg_temp.drive('dc100000-0000-0000-0000-000000000004', 8, 3000, 25, pg_temp.track(121, 25, 'out_and_back', 2, 5));
-- A claimed distance the track can't support.
select pg_temp.drive('dc100000-0000-0000-0000-000000000005', 10, 100000, 25, pg_temp.track(121, 25, 'straight', 2, 5));
update public.privacy_settings set leaderboard_opt_in = true;

reset role;

-- 1–2: an ordinary drive counts in full.
select is((select validation_status from public.drives where id = 'dc100000-0000-0000-0000-000000000001'), 'validated',
  'a straight drive validates');
select ok(abs(pg_temp.ranked('dc100000-0000-0000-0000-000000000001') - 3000) < 150,
  'its leaderboard distance is within 5 % of the 3 km driven');

-- 3–5: jitter while parked used to count, and no longer does.
select is((select validation_status from public.drives where id = 'dc100000-0000-0000-0000-000000000002'), 'validated',
  'a parked recording validates');
select ok((select server_distance_m > 5000 from public.drives where id = 'dc100000-0000-0000-0000-000000000002'),
  'the raw sum of its jitter is kilometres');
select ok(pg_temp.ranked('dc100000-0000-0000-0000-000000000002') < 50,
  'its leaderboard distance is under 50 m');

-- 6–7: back and forth over the same road adds at most two passes.
select is((select validation_status from public.drives where id = 'dc100000-0000-0000-0000-000000000003'), 'validated',
  'an oscillating drive validates');
select ok(pg_temp.ranked('dc100000-0000-0000-0000-000000000003') < 1000,
  'its leaderboard distance is under 1 km, not 15');

-- 8–9: an out-and-back drive is counted both ways.
select is((select validation_status from public.drives where id = 'dc100000-0000-0000-0000-000000000004'), 'validated',
  'an out-and-back drive validates');
select ok(abs(pg_temp.ranked('dc100000-0000-0000-0000-000000000004') - 3000) < 150,
  'its leaderboard distance is within 5 % of the 3 km driven');

-- 10: a rejected drive gets no figure.
select is(pg_temp.ranked('dc100000-0000-0000-0000-000000000005'), null, 'a rejected drive has no leaderboard distance');

-- 11–12: the board sums the new figure.
select ok(abs((select value from public.leaderboard('distance', 'global', 'all_time') where is_me)
              - (select sum(s.ranked_distance_m) from private.drive_scores s
                   join public.drives d on d.id = s.drive_id
                  where d.owner_id = 'dc000000-0000-0000-0000-00000000000a' and d.validation_status = 'validated')) < 1,
  'the distance board sums leaderboard distances');
select ok((select value from public.leaderboard('distance', 'global', 'all_time') where is_me)
          < (select sum(server_distance_m) from public.drives
              where owner_id = 'dc000000-0000-0000-0000-00000000000a' and validation_status = 'validated') / 2,
  'which is far below the raw sum these drives used to score');

-- 13–14: the figures and the helper stay private.
select pg_temp.act_as('dc000000-0000-0000-0000-00000000000a');
select throws_ok($$ select * from private.drive_scores $$, '42501', null, 'clients cannot read leaderboard distances');
select throws_ok($$ select private.track_coverage_m('[]') $$, '42501', null, 'clients cannot call the coverage helper');

-- 15–16: hops across the antimeridian take the short way round.
reset role;
select ok(abs(private.track_coverage_m((
    select jsonb_agg(jsonb_build_array(i, 0, 179.9865 + i * 0.0009 - case when 179.9865 + i * 0.0009 >= 180 then 360 else 0 end) order by i)
    from generate_series(0, 30) as i)) - 3000) < 300,
  'a 3 km drive east across the antimeridian covers about 3 km');
select ok(private.track_coverage_m((
    select jsonb_agg(jsonb_build_array(i, 38.58, case when i % 2 = 0 then 179.99 else -179.99 end) order by i)
    from generate_series(0, 999) as i)) < 4500,
  '1,000 passes over 1.7 km across the antimeridian count as about two');

-- 17: the fill-in work is capped for the whole track, not only per hop:
-- 250 hops of 111 km fill only the first 20,000 km or so.
select ok(private.track_coverage_m((
    select jsonb_agg(jsonb_build_array(i, 0, -120 + i) order by i)
    from generate_series(0, 249) as i)) between 21500000 and 23000000,
  'fill-in stops after 400,000 steps');

select * from finish();
rollback;
