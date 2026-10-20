-- The app now measures moving distance from Doppler speed (Phase 3 M3),
-- which is shorter than the sum of every position change: GPS noise adds
-- roughly 10 % at low speed. validate_drive compared the app's distance with
-- that sum and flagged a difference above 5 %, so ordinary stop-and-go
-- drives would have lost "validated". It now also computes a lower bound
-- (straight hops between well-separated fixes, each less both fixes'
-- accuracy radii, restarting wherever the app relocked after a jump) and
-- accepts the app's figure anywhere between the two, with the same
-- 5 % / 50 m and 25 % / 200 m margins as before. server_distance_m is
-- still the raw sum.
--
-- Reversible: supabase/rollback/20261020000200_drive_distance_bounds_down.sql
-- restores the previous definition. No data is touched; drives already
-- validated keep their status.

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
  anchor_lat double precision;
  anchor_lon double precision;
  anchor_hacc double precision;
  from_anchor double precision;
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
        if seg / dt > 120 then
          jumps := jumps + 1; -- teleport; don't count it
        else
          dist := dist + seg;
        end if;
        -- Lower bound: hop from fix to fix once they are well apart, and
        -- credit each hop less both fixes' accuracy radii, which is the
        -- least the car can have moved between them. A step the app's own
        -- jump check rejects (faster than 120 m/s, or further than the
        -- Doppler speeds allow) is where it relocked and added nothing, so
        -- the bound restarts from there instead of spanning it.
        if seg / dt > 120
           or (coalesce(prev_spd, -1) >= 0 and coalesce(prev_sacc, -1) >= 0
               and coalesce(rec.spd, -1) >= 0 and coalesce(rec.sacc, -1) >= 0 and dt <= 5
               and seg > (greatest(prev_spd + prev_sacc, rec.spd + rec.sacc) + 2) * dt
                         + coalesce(prev_hacc, 0) + coalesce(rec.hacc, 0)) then
          anchor_lat := rec.lat;
          anchor_lon := rec.lon;
          anchor_hacc := rec.hacc;
        else
          from_anchor := public.haversine_m(anchor_lat, anchor_lon, rec.lat, rec.lon);
          if from_anchor > greatest(5, 2 * (coalesce(anchor_hacc, 0) + coalesce(rec.hacc, 0))) then
            low_dist := low_dist + from_anchor - coalesce(anchor_hacc, 0) - coalesce(rec.hacc, 0);
            anchor_lat := rec.lat;
            anchor_lon := rec.lon;
            anchor_hacc := rec.hacc;
          end if;
        end if;
      end if;
    end if;
    if prev_t is null then
      anchor_lat := rec.lat;
      anchor_lon := rec.lon;
      anchor_hacc := rec.hacc;
    end if;
    prev_t := rec.t;
    prev_lat := rec.lat;
    prev_lon := rec.lon;
    prev_spd := rec.spd;
    prev_sacc := rec.sacc;
    prev_hacc := rec.hacc;
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

  insert into public.notifications (recipient_id, kind, drive_id)
  values (d.owner_id, 'drive_validated', d.id);

  return status;
end;
$$;
