-- Distance leaderboards that resist inflated tracks
-- (/mnt/project-files/phase3/LEADERBOARD_DISTANCE_PROPOSAL.md, rules 1 and 2;
-- Aarav chose "count repeated road twice" on 2026-10-20).
--
-- The distance and drives boards summed server_distance_m, the raw sum of
-- every segment. Two things inflated it with no fabrication at all: GPS
-- jitter while parked (each step small and plausible), and going back and
-- forth over the same few hundred metres. A drive's leaderboard distance is
-- now the smaller of:
--   * its anchored distance: hops between fixes once they are well apart
--     (the same hops validate_drive's lower bound uses, credited in full),
--     so jitter inside the fixes' accuracy radii adds nothing; and
--   * its coverage: the ~100 m grid cells the track passes through, each
--     counted once per visit and at most twice, so an out-and-back drive
--     counts in full but more passes over the same road add nothing.
-- Neither ever exceeds what the car really covered on an ordinary drive, so
-- taking the smaller only removes inflation. Fabricated tracks that look
-- physically real are not addressed here (rules 3 to 5 of the proposal).
--
-- The figure lives in private.drive_scores, which only the leaderboard (a
-- definer function) reads; server_distance_m and everything clients see
-- are unchanged. Drives validated before this migration are backfilled from
-- their stored tracks as least(server_distance_m, coverage): the anchored
-- distance needs a full revalidation, which would also re-notify owners.
--
-- Reversible: supabase/rollback/20261020000300_leaderboard_ranked_distance_down.sql
-- restores validate_drive and leaderboard and drops the table, which holds
-- only derived figures.

create table private.drive_scores (
  drive_id uuid primary key references public.drives (id) on delete cascade deferrable initially deferred,
  ranked_distance_m double precision not null
);
revoke all on private.drive_scores from public, anon, authenticated;

-- Metres of ground a track covers: the ~100 m cells (0.0009 degrees of
-- latitude, and of longitude scaled by the first fix's latitude) it passes
-- through, each counted once per visit and at most twice. Hops are filled
-- in every 50 m, so a signal gap still covers the cells it crossed; at most
-- 2,000 fills a hop, and 400,000 the whole track (20,000 km, beyond any real drive), after
-- which each hop only counts its end. Both caps only ever lower the figure
-- and keep the work proportional to the track's length. Longitude steps
-- take the short way round, so a hop across the antimeridian stays local.
create function private.track_coverage_m(pts jsonb)
returns double precision
language sql
immutable
parallel safe
set search_path = ''
as $$
  with fixes as (
    select i, (p ->> 1)::float8 as lat, (p ->> 2)::float8 as lon
    from jsonb_array_elements(pts) with ordinality as e(p, i)
  ),
  hops as (
    select i, lat, plat, plon, dlon - 360 * round(dlon / 360) as dlon, xscale,
           least(2000, greatest(1, ceil(public.haversine_m(plat, plon, lat, lon) / 50)))::int as m
    from (
      select i, lat, lon, cos(radians(first_value(lat) over (order by i))) as xscale,
             coalesce(lag(lat) over (order by i), lat) as plat,
             coalesce(lag(lon) over (order by i), lon) as plon,
             lon - coalesce(lag(lon) over (order by i), lon) as dlon
      from fixes
    ) as f
  ),
  budget as (
    select h.*, greatest(1, least(h.m, 400000 - coalesce(sum(h.m) over (order by h.i rows between unbounded preceding and 1 preceding), 0)))::int as fill
    from hops h
  ),
  steps as (
    select b.i, k.k, b.xscale, b.plat + (b.lat - b.plat) * k.k / b.fill::float8 as lat,
           b.plon + b.dlon * k.k / b.fill::float8 as lon
    from budget b
    cross join lateral generate_series(1, b.fill) as k(k)
  ),
  cells as (
    select i, k, floor(lat / 0.0009)::bigint as cy, floor((lon - 360 * floor((lon + 180) / 360)) * xscale / 0.0009)::bigint as cx
    from steps
  ),
  entries as (
    select cy, cx, (cy, cx) is distinct from (lag(cy) over w, lag(cx) over w) as entered
    from cells
    window w as (order by i, k)
  )
  select coalesce(sum(least(visits, 2)), 0) * 100.0
  from (select count(*) filter (where entered) as visits from entries group by cy, cx) as v;
$$;
revoke execute on function private.track_coverage_m(jsonb) from public, anon, authenticated;

-- A drive whose owner has since deleted its track keeps the figure it
-- ranked on before.
insert into private.drive_scores (drive_id, ranked_distance_m)
select d.id, case when t.drive_id is null then d.server_distance_m
                  else least(d.server_distance_m, private.track_coverage_m(t.points)) end
from public.drives d
left join public.drive_tracks t on t.drive_id = d.id
where d.validation_status in ('validated', 'flagged') and d.server_distance_m is not null;

create or replace function private.validate_drive(p_drive uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  d public.drives;
  pts jsonb;
  n integer;
  rec record;
  prev_t double precision;
  prev_lat double precision;
  prev_lon double precision;
  prev_spd double precision;
  prev_sacc double precision;
  prev_hacc double precision;
  dist double precision := 0;
  low_dist double precision := 0;
  anch_dist double precision := 0;
  anchor_lat double precision;
  anchor_lon double precision;
  anchor_hacc double precision;
  from_anchor double precision;
  err double precision;
  relocked boolean;
  seg double precision;
  dt double precision;
  max_doppler double precision := 0;
  jumps integer := 0;
  non_monotonic integer := 0;
  hacc_min double precision := 1e9;
  hacc_max double precision := -1;
  alt_min double precision := 1e9;
  alt_max double precision := -1e9;
  duration double precision;
  notes text[] := '{}';
  hard boolean := false;
  status text;
  cells text[];
  vehicle_kind public.vehicle_kind;
  speed_cap double precision;
begin
  select * into d from public.drives where id = p_drive;
  select points into pts from public.drive_tracks where drive_id = p_drive;
  if d.id is null or pts is null then
    return null;
  end if;
  n := jsonb_array_length(pts);

  for rec in
    select (p ->> 0)::float8 as t, (p ->> 1)::float8 as lat, (p ->> 2)::float8 as lon,
           (p ->> 3)::float8 as alt, (p ->> 4)::float8 as spd, (p ->> 5)::float8 as hacc,
           (p ->> 7)::float8 as sacc
    from jsonb_array_elements(pts) with ordinality as e(p, i)
    order by i
  loop
    if rec.hacc is not null then
      hacc_min := least(hacc_min, rec.hacc);
      hacc_max := greatest(hacc_max, rec.hacc);
    end if;
    alt_min := least(alt_min, coalesce(rec.alt, 0));
    alt_max := greatest(alt_max, coalesce(rec.alt, 0));
    if coalesce(rec.spd, -1) >= 0 then
      max_doppler := greatest(max_doppler, rec.spd);
    end if;
    if prev_t is not null then
      dt := rec.t - prev_t;
      if dt <= 0 then
        non_monotonic := non_monotonic + 1;
      else
        seg := public.haversine_m(prev_lat, prev_lon, rec.lat, rec.lon);
        -- A step the app's own jump check rejects (faster than 120 m/s once
        -- both accuracy radii are forgiven, or further than the Doppler
        -- speeds allow) is where it relocked and added nothing, so neither
        -- the raw sum nor the lower bound spans it; the bound restarts there.
        err := least(greatest(coalesce(rec.hacc, 0), 0), 35);
        relocked := greatest(0, seg - coalesce(prev_hacc, 0) - err) / dt > 120
          or (coalesce(prev_spd, -1) >= 0 and coalesce(prev_sacc, -1) >= 0
              and coalesce(rec.spd, -1) >= 0 and coalesce(rec.sacc, -1) >= 0 and dt <= 5
              and seg > (greatest(prev_spd + prev_sacc, rec.spd + rec.sacc) + 2) * dt + prev_hacc + err);
        if relocked then
          jumps := jumps + 1; -- a relock either way; don't count it
        else
          dist := dist + seg;
        end if;
        -- Lower bound: hop from fix to fix once they are well apart, and
        -- credit each hop less both fixes' accuracy radii, which is the
        -- least the car can have moved between them. Radii are clamped to
        -- 0–35 m, the most the app accepts, so an inflated accuracy in the
        -- upload can't wipe the bound out.
        if relocked then
          anchor_lat := rec.lat;
          anchor_lon := rec.lon;
          anchor_hacc := err;
        else
          from_anchor := public.haversine_m(anchor_lat, anchor_lon, rec.lat, rec.lon);
          if from_anchor > greatest(5, 2 * (anchor_hacc + err)) then
            low_dist := low_dist + from_anchor - anchor_hacc - err;
            anch_dist := anch_dist + from_anchor;
            anchor_lat := rec.lat;
            anchor_lon := rec.lon;
            anchor_hacc := err;
          end if;
        end if;
      end if;
    end if;
    if prev_t is null then
      anchor_lat := rec.lat;
      anchor_lon := rec.lon;
      anchor_hacc := least(greatest(coalesce(rec.hacc, 0), 0), 35);
    end if;
    prev_t := rec.t;
    prev_lat := rec.lat;
    prev_lon := rec.lon;
    prev_spd := rec.spd;
    prev_sacc := rec.sacc;
    prev_hacc := least(greatest(coalesce(rec.hacc, 0), 0), 35);
  end loop;

  duration := coalesce(prev_t, 0);

  if n < 30 then
    notes := array_append(notes, 'too_few_samples'); hard := true;
  end if;
  if non_monotonic > 0 then
    notes := array_append(notes, 'non_monotonic_time'); hard := true;
  end if;
  if d.ended_at > now() + interval '5 minutes' then
    notes := array_append(notes, 'ends_in_future'); hard := true;
  end if;
  if abs(duration - d.elapsed_s) > greatest(120, d.elapsed_s * 0.1) then
    notes := array_append(notes, 'duration_mismatch'); hard := true;
  end if;
  -- GPS noise makes the sum of every segment (dist) longer than the drive
  -- really was, most at low speed, and the app measures moving distance
  -- from Doppler speed. So the app's figure should land between the
  -- lower bound and the raw sum, not on the raw sum.
  if dist > 0 and (d.distance_m > dist + greatest(200, dist * 0.25)
                   or d.distance_m < low_dist - greatest(200, low_dist * 0.25)) then
    notes := array_append(notes, 'distance_mismatch'); hard := true;
  elsif d.distance_m > dist + greatest(50, dist * 0.05)
        or d.distance_m < low_dist - greatest(50, low_dist * 0.05) then
    notes := array_append(notes, 'distance_drift');
  end if;
  if duration > 0 and n::float8 / duration < 0.2 then
    notes := array_append(notes, 'sparse_samples');
  end if;
  if jumps > greatest(3, n / 100) then
    notes := array_append(notes, 'position_jumps');
  end if;
  if d.top_speed_mps is not null and d.top_speed_mps > max_doppler + 1.5 then
    notes := array_append(notes, 'top_speed_not_in_track'); hard := true;
  end if;
  -- Simulated tracks frequently report perfectly constant accuracy and a
  -- flat altitude. Real phones never do over hundreds of fixes.
  if n >= 120 and hacc_max - hacc_min < 0.01 then
    notes := array_append(notes, 'uniform_accuracy');
  end if;
  if n >= 120 and alt_max - alt_min < 0.01 then
    notes := array_append(notes, 'flat_altitude');
  end if;
  select v.kind into vehicle_kind from public.vehicles v where v.id = d.vehicle_id;
  speed_cap := case when vehicle_kind = 'motorcycle' then 95 else 90 end; -- ~210 / 200 mph
  if max_doppler > speed_cap then
    notes := array_append(notes, 'implausible_speed');
  end if;
  if exists (
    select 1 from public.drives o
    where o.owner_id = d.owner_id and o.id <> d.id and o.validation_status in ('validated', 'flagged')
      and tstzrange(o.started_at, o.ended_at) && tstzrange(d.started_at, d.ended_at)
  ) then
    notes := array_append(notes, 'overlaps_other_drive');
  end if;

  status := case when hard then 'rejected' when cardinality(notes) > 0 then 'flagged' else 'validated' end;

  -- ~1.1 km grid cells for the exploration leaderboard.
  select coalesce(array_agg(distinct format('%s:%s', floor((p ->> 1)::float8 * 100)::int, floor((p ->> 2)::float8 * 100)::int)), '{}')
    into cells
  from jsonb_array_elements(pts) as e(p);

  update public.drives
     set validation_status = status,
         validation_notes = notes,
         server_distance_m = dist,
         server_top_speed_mps = max_doppler,
         explored_cells = case when status = 'rejected' then '{}' else cells end
   where id = p_drive;

  -- What the distance leaderboards count (see private.drive_scores).
  if status = 'rejected' then
    delete from private.drive_scores where drive_id = p_drive;
  else
    insert into private.drive_scores (drive_id, ranked_distance_m)
    values (p_drive, least(anch_dist, private.track_coverage_m(pts)))
    on conflict (drive_id) do update set ranked_distance_m = excluded.ranked_distance_m;
  end if;

  insert into public.notifications (recipient_id, kind, drive_id)
  values (d.owner_id, 'drive_validated', d.id);

  return status;
end;
$$;

create or replace function public.leaderboard(
  p_metric text,
  p_scope text default 'global',
  p_period text default 'week',
  p_vehicle_kind public.vehicle_kind default null,
  p_limit integer default 50
)
returns table (rank bigint, profile jsonb, value double precision, vehicle_title text, is_me boolean)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  viewer uuid := auth.uid();
  since timestamptz;
  my_country text;
  my_region text;
  performance boolean := p_metric in ('zero_to_sixty', 'top_speed');
begin
  if viewer is null then
    raise exception 'sign in required' using errcode = '42501';
  end if;
  if p_metric not in ('distance', 'drives', 'exploration', 'community', 'zero_to_sixty', 'top_speed') then
    raise exception 'unknown metric %', p_metric using errcode = '22023';
  end if;
  if p_scope not in ('global', 'country', 'region', 'friends') then
    raise exception 'unknown scope %', p_scope using errcode = '22023';
  end if;
  since := case p_period
    when 'week' then date_trunc('week', now())
    when 'month' then date_trunc('month', now())
    when 'all_time' then '-infinity'::timestamptz
    else null end;
  if since is null then
    raise exception 'unknown period %', p_period using errcode = '22023';
  end if;
  select country_code, region_code into my_country, my_region from public.profile_details where user_id = viewer;
  if p_scope = 'country' and my_country is null then
    raise exception 'set your country in your profile to see country rankings' using errcode = '22023';
  end if;
  if p_scope = 'region' and my_region is null then
    raise exception 'set your region in your profile to see regional rankings' using errcode = '22023';
  end if;

  return query
  with eligible as (
    select p.id, p.username, p.display_name, p.avatar_path
    from public.profiles p
    join public.privacy_settings ps on ps.user_id = p.id
    join public.profile_details pd on pd.user_id = p.id
    where ps.leaderboard_opt_in
      and (not performance or ps.performance_leaderboard_opt_in)
      and p.visibility <> 'private'
      and not public.is_blocked_between(p.id, viewer)
      and case p_scope
            when 'country' then pd.country_code = my_country
            when 'region' then pd.region_code = my_region
            when 'friends' then p.id = viewer or public.is_friend(p.id, viewer)
            else true end
  ),
  drives as (
    select d.*, v.kind as vkind, v.year, v.make, v.model, coalesce(s.ranked_distance_m, 0) as ranked_m
    from public.drives d
    join eligible e on e.id = d.owner_id
    left join public.vehicles v on v.id = d.vehicle_id
    left join private.drive_scores s on s.drive_id = d.id
    where d.validation_status = 'validated'
      and d.started_at >= since
      and (p_vehicle_kind is null or v.kind = p_vehicle_kind)
      and (not performance or d.closed_course_meet_id is not null)
  ),
  scores as (
    select d.owner_id as uid, sum(d.ranked_m) as score, null::uuid as best_drive
      from drives d where p_metric = 'distance' group by d.owner_id
    union all
    select d.owner_id, count(*)::float8, null from drives d
      where p_metric = 'drives' and d.ranked_m >= 1000 group by d.owner_id
    union all
    select x.owner_id, count(distinct x.cell)::float8, null
      from (select d.owner_id, unnest(c.cells) as cell
              from drives d join private.drive_cells c on c.drive_id = d.id
             where p_metric = 'exploration') x
      group by x.owner_id
    union all
    select e.id,
           ((select count(*) from public.meet_rsvps r join public.meets m on m.id = r.meet_id
              where r.user_id = e.id and r.status = 'going' and m.cancelled_at is null
                and m.ends_at < now() and m.ends_at >= since)
            + 2 * (select count(*) from public.meets m
              where m.host_id = e.id and m.cancelled_at is null and m.ends_at < now() and m.ends_at >= since
                and (select count(*) from public.meet_rsvps r where r.meet_id = m.id and r.status = 'going') >= 3))::float8,
           null
      from eligible e where p_metric = 'community'
    union all
    (select distinct on (d.owner_id) d.owner_id, d.zero_to_sixty_s, d.id
      from drives d
      where p_metric = 'zero_to_sixty' and d.zero_to_sixty_s is not null and d.zero_to_sixty_quality = 'consistent'
      order by d.owner_id, d.zero_to_sixty_s asc)
    union all
    (select distinct on (d.owner_id) d.owner_id, least(d.top_speed_mps, d.server_top_speed_mps), d.id
      from drives d
      where p_metric = 'top_speed' and d.top_speed_mps is not null
      order by d.owner_id, least(d.top_speed_mps, d.server_top_speed_mps) desc)
  ),
  ranked as (
    select s.uid, s.score, s.best_drive,
           rank() over (order by case when p_metric = 'zero_to_sixty' then s.score else -s.score end) as r
    from scores s
    where s.score is not null and s.score > 0
  )
  select ranked.r,
         jsonb_build_object('id', e.id, 'username', e.username, 'display_name', e.display_name, 'avatar_path', e.avatar_path),
         ranked.score,
         (select format('%s %s %s', v.year, v.make, v.model)
            from public.drives d join public.vehicles v on v.id = d.vehicle_id
           where d.id = ranked.best_drive and public.can_view(v.owner_id, v.visibility)),
         e.id = viewer
  from ranked
  join eligible e on e.id = ranked.uid
  where ranked.r <= least(greatest(p_limit, 1), 200) or e.id = viewer
  order by ranked.r, e.username;
end;
$$;
