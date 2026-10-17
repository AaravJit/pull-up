-- Drives, raw tracks, privacy zones, server-side validation and redacted
-- route sharing.
--
-- Data separation
--   drives               statistics only; visible per (drive visibility ∧ the
--                        owner's drive-history ceiling)
--   drive_tracks         full-resolution GPS; owner only, forever
--   drive_shared_routes  redacted polyline produced by the server; follows the
--                        drive's visibility; clients cannot write it
--   privacy_zones        owner only

create table public.drives (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles (id) on delete cascade,
  vehicle_id uuid references public.vehicles (id) on delete set null,
  title text not null default '' check (char_length(title) <= 80),
  started_at timestamptz not null,
  ended_at timestamptz not null,
  distance_m double precision not null check (distance_m >= 0),
  moving_s double precision not null check (moving_s >= 0),
  stopped_s double precision not null check (stopped_s >= 0),
  elapsed_s double precision not null check (elapsed_s >= 0),
  top_speed_mps double precision check (top_speed_mps >= 0),
  avg_moving_speed_mps double precision check (avg_moving_speed_mps >= 0),
  elevation_gain_m double precision not null default 0,
  elevation_loss_m double precision not null default 0,
  zero_to_sixty_s double precision check (zero_to_sixty_s > 0),
  zero_to_sixty_quality text check (zero_to_sixty_quality in ('insufficient', 'estimate', 'consistent')),
  visibility public.visibility not null default 'private',
  client_version text not null default '',
  -- Server-owned columns (protected by trigger).
  validation_status text not null default 'pending'
    check (validation_status in ('pending', 'validated', 'flagged', 'rejected')),
  validation_notes text[] not null default '{}',
  server_distance_m double precision,
  server_top_speed_mps double precision,
  explored_cells text[] not null default '{}',
  closed_course_meet_id uuid,
  has_shared_route boolean not null default false,
  created_at timestamptz not null default now(),
  check (ended_at > started_at),
  check (ended_at - started_at <= interval '24 hours')
);
create index drives_owner_idx on public.drives (owner_id, started_at desc);
create index drives_leaderboard_idx on public.drives (started_at) where validation_status = 'validated';

create table public.drive_tracks (
  drive_id uuid primary key references public.drives (id) on delete cascade,
  owner_id uuid not null references public.profiles (id) on delete cascade,
  -- [[t_offset_s, lat, lon, alt_m, speed_mps, h_acc_m, v_acc_m, speed_acc_mps], ...]
  points jsonb not null check (jsonb_typeof(points) = 'array'),
  created_at timestamptz not null default now()
);

create table public.drive_shared_routes (
  drive_id uuid primary key references public.drives (id) on delete cascade,
  -- [[[lat, lon], ...], ...] visible segments after redaction
  segments jsonb not null,
  created_at timestamptz not null default now()
);

create table public.privacy_zones (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  label text not null default 'Private place' check (char_length(label) <= 40),
  lat double precision not null check (lat between -90 and 90),
  lon double precision not null check (lon between -180 and 180),
  radius_m double precision not null default 300 check (radius_m between 100 and 2000),
  created_at timestamptz not null default now()
);
create index privacy_zones_user_idx on public.privacy_zones (user_id);

-- ---------------------------------------------------------------------------
-- Geometry helpers (no PostGIS needed; matches Coordinate.distance in Swift)
-- ---------------------------------------------------------------------------

create or replace function public.haversine_m(lat1 double precision, lon1 double precision, lat2 double precision, lon2 double precision)
returns double precision
language sql
immutable
parallel safe
set search_path = ''
as $$
  select 2 * 6371008.8 * asin(least(1, sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2)
    + cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lon2 - lon1) / 2), 2)
  )));
$$;

-- ---------------------------------------------------------------------------
-- Guards
-- ---------------------------------------------------------------------------

create or replace function private.guard_drive()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not private.is_trusted() then
    if tg_op = 'INSERT' then
      new.validation_status := 'pending';
      new.validation_notes := '{}';
      new.server_distance_m := null;
      new.server_top_speed_mps := null;
      new.explored_cells := '{}';
      new.closed_course_meet_id := null;
      new.has_shared_route := false;
    else
      if new.owner_id <> old.owner_id then
        raise exception 'drive owner is immutable' using errcode = '42501';
      end if;
      -- Statistics are frozen once submitted; only presentation may change.
      new.started_at := old.started_at;
      new.ended_at := old.ended_at;
      new.distance_m := old.distance_m;
      new.moving_s := old.moving_s;
      new.stopped_s := old.stopped_s;
      new.elapsed_s := old.elapsed_s;
      new.top_speed_mps := old.top_speed_mps;
      new.avg_moving_speed_mps := old.avg_moving_speed_mps;
      new.elevation_gain_m := old.elevation_gain_m;
      new.elevation_loss_m := old.elevation_loss_m;
      new.zero_to_sixty_s := old.zero_to_sixty_s;
      new.zero_to_sixty_quality := old.zero_to_sixty_quality;
      new.validation_status := old.validation_status;
      new.validation_notes := old.validation_notes;
      new.server_distance_m := old.server_distance_m;
      new.server_top_speed_mps := old.server_top_speed_mps;
      new.explored_cells := old.explored_cells;
      new.closed_course_meet_id := old.closed_course_meet_id;
      new.has_shared_route := old.has_shared_route;
    end if;
  end if;
  if new.vehicle_id is not null and not exists (
    select 1 from public.vehicles v where v.id = new.vehicle_id and v.owner_id = new.owner_id
  ) then
    raise exception 'vehicle does not belong to the driver' using errcode = '42501';
  end if;
  return new;
end;
$$;

create trigger drives_guard before insert or update on public.drives
  for each row execute function private.guard_drive();

create or replace function public.drive_history_ceiling(p_owner uuid)
returns public.visibility
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select drive_history_visibility from public.privacy_settings where user_id = p_owner), 'private'::public.visibility);
$$;

create or replace function public.can_view_drive(p_drive uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.drives d
    where d.id = p_drive
      and public.can_view(d.owner_id, public.least_visibility(d.visibility, public.drive_history_ceiling(d.owner_id)))
  );
$$;

-- ---------------------------------------------------------------------------
-- Validation (anti-spoofing). Runs when the track is uploaded.
-- ---------------------------------------------------------------------------

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
  dist double precision := 0;
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
           (p ->> 3)::float8 as alt, (p ->> 4)::float8 as spd, (p ->> 5)::float8 as hacc
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
      end if;
    end if;
    prev_t := rec.t;
    prev_lat := rec.lat;
    prev_lon := rec.lon;
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
  if dist > 0 and abs(dist - d.distance_m) > greatest(200, dist * 0.25) then
    notes := array_append(notes, 'distance_mismatch'); hard := true;
  elsif abs(dist - d.distance_m) > greatest(50, dist * 0.05) then
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

create or replace function private.guard_track()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.drives where id = new.drive_id and owner_id = new.owner_id) then
    raise exception 'track must belong to the drive owner' using errcode = '42501';
  end if;
  if jsonb_array_length(new.points) > 200000 then
    raise exception 'track too large' using errcode = '22023';
  end if;
  return new;
end;
$$;

create or replace function private.after_track_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.validate_drive(new.drive_id);
  return new;
end;
$$;

create trigger drive_tracks_guard before insert on public.drive_tracks
  for each row execute function private.guard_track();
create trigger drive_tracks_validate after insert on public.drive_tracks
  for each row execute function private.after_track_insert();

-- ---------------------------------------------------------------------------
-- Route sharing with redaction
-- ---------------------------------------------------------------------------

-- Builds visible segments from the raw track:
--   1. drops every point within (zone radius + 150 m) of a privacy zone
--   2. trims the configured distance plus a random 0–250 m from each end, so
--      the true start and end can't be found by subtracting a known constant
--   3. thins points to ≥ 25 m apart and rounds to 4 decimals (~11 m)
create or replace function private.build_shared_route(p_drive uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  d public.drives;
  pts jsonb;
  trim_m double precision;
  start_trim double precision;
  end_trim double precision;
  total double precision := 0;
  along double precision[] := '{}';
  lats double precision[] := '{}';
  lons double precision[] := '{}';
  rec record;
  i integer;
  hidden boolean;
  segments jsonb := '[]'::jsonb;
  current_seg jsonb := '[]'::jsonb;
  last_lat double precision;
  last_lon double precision;
begin
  select * into d from public.drives where id = p_drive;
  select points into pts from public.drive_tracks where drive_id = p_drive;
  if pts is null then
    return '[]'::jsonb;
  end if;
  select route_endpoint_trim_m into trim_m from public.privacy_settings where user_id = d.owner_id;
  trim_m := greatest(coalesce(trim_m, 400), 200);
  start_trim := trim_m + random() * 250;
  end_trim := trim_m + random() * 250;

  for rec in
    select (p ->> 1)::float8 as lat, (p ->> 2)::float8 as lon
    from jsonb_array_elements(pts) with ordinality as e(p, ord) order by ord
  loop
    if cardinality(lats) > 0 then
      total := total + public.haversine_m(lats[cardinality(lats)], lons[cardinality(lons)], rec.lat, rec.lon);
    end if;
    lats := lats || rec.lat;
    lons := lons || rec.lon;
    along := along || total;
  end loop;

  if total <= start_trim + end_trim + 200 then
    return '[]'::jsonb;
  end if;

  for i in 1 .. cardinality(lats) loop
    hidden := along[i] < start_trim or along[i] > total - end_trim
      or exists (
        select 1 from public.privacy_zones z
        where z.user_id = d.owner_id
          and public.haversine_m(z.lat, z.lon, lats[i], lons[i]) <= z.radius_m + 150
      );
    if hidden then
      if jsonb_array_length(current_seg) >= 2 then
        segments := segments || jsonb_build_array(current_seg);
      end if;
      current_seg := '[]'::jsonb;
      last_lat := null;
    elsif last_lat is null or public.haversine_m(last_lat, last_lon, lats[i], lons[i]) >= 25 then
      current_seg := current_seg || jsonb_build_array(jsonb_build_array(round(lats[i]::numeric, 4), round(lons[i]::numeric, 4)));
      last_lat := lats[i];
      last_lon := lons[i];
    end if;
  end loop;
  if jsonb_array_length(current_seg) >= 2 then
    segments := segments || jsonb_build_array(current_seg);
  end if;
  return segments;
end;
$$;

create or replace function public.share_drive_route(p_drive uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  owner uuid;
  allowed boolean;
  segs jsonb;
begin
  select owner_id into owner from public.drives where id = p_drive;
  if owner is null or owner <> auth.uid() then
    raise exception 'not your drive' using errcode = '42501';
  end if;
  select allow_route_sharing into allowed from public.privacy_settings where user_id = owner;
  if not coalesce(allowed, false) then
    raise exception 'route sharing is turned off in privacy settings' using errcode = '42501';
  end if;
  segs := private.build_shared_route(p_drive);
  if jsonb_array_length(segs) = 0 then
    raise exception 'route too short to share without revealing its endpoints' using errcode = '22023';
  end if;
  insert into public.drive_shared_routes (drive_id, segments) values (p_drive, segs)
  on conflict (drive_id) do update set segments = excluded.segments, created_at = now();
  update public.drives set has_shared_route = true where id = p_drive;
  return segs;
end;
$$;

create or replace function public.unshare_drive_route(p_drive uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.drives where id = p_drive and owner_id = auth.uid()) then
    raise exception 'not your drive' using errcode = '42501';
  end if;
  delete from public.drive_shared_routes where drive_id = p_drive;
  update public.drives set has_shared_route = false where id = p_drive;
end;
$$;

-- Adding or moving a zone re-redacts every route already shared, and
-- turning sharing off withdraws them all.
create or replace function private.reshare_after_zone_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := coalesce(new.user_id, old.user_id);
  r record;
  segs jsonb;
begin
  for r in select dsr.drive_id from public.drive_shared_routes dsr join public.drives d on d.id = dsr.drive_id where d.owner_id = uid loop
    segs := private.build_shared_route(r.drive_id);
    if jsonb_array_length(segs) = 0 then
      delete from public.drive_shared_routes where drive_id = r.drive_id;
      update public.drives set has_shared_route = false where id = r.drive_id;
    else
      update public.drive_shared_routes set segments = segs where drive_id = r.drive_id;
    end if;
  end loop;
  return null;
end;
$$;

create trigger privacy_zones_reshare after insert or update or delete on public.privacy_zones
  for each row execute function private.reshare_after_zone_change();

create or replace function private.withdraw_routes_when_sharing_disabled()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.allow_route_sharing and not new.allow_route_sharing then
    delete from public.drive_shared_routes dsr using public.drives d
     where d.id = dsr.drive_id and d.owner_id = new.user_id;
    update public.drives set has_shared_route = false where owner_id = new.user_id and has_shared_route;
  end if;
  return new;
end;
$$;

create trigger privacy_settings_withdraw after update on public.privacy_settings
  for each row execute function private.withdraw_routes_when_sharing_disabled();

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------

alter table public.drives enable row level security;
alter table public.drive_tracks enable row level security;
alter table public.drive_shared_routes enable row level security;
alter table public.privacy_zones enable row level security;

create policy "Drives: visible per visibility and history ceiling"
  on public.drives for select to authenticated
  using (public.can_view(owner_id, public.least_visibility(visibility, public.drive_history_ceiling(owner_id))));
create policy "Drives: owner inserts"
  on public.drives for insert to authenticated with check (owner_id = auth.uid());
create policy "Drives: owner updates presentation"
  on public.drives for update to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy "Drives: owner deletes"
  on public.drives for delete to authenticated using (owner_id = auth.uid());

create policy "Tracks: owner only"
  on public.drive_tracks for select to authenticated using (owner_id = auth.uid());
create policy "Tracks: owner uploads"
  on public.drive_tracks for insert to authenticated with check (owner_id = auth.uid());
create policy "Tracks: owner deletes"
  on public.drive_tracks for delete to authenticated using (owner_id = auth.uid());

create policy "Shared routes: follow the drive"
  on public.drive_shared_routes for select to authenticated using (public.can_view_drive(drive_id));

create policy "Privacy zones: owner only"
  on public.privacy_zones for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

grant execute on function public.share_drive_route(uuid) to authenticated;
grant execute on function public.unshare_drive_route(uuid) to authenticated;
grant execute on function public.can_view_drive(uuid) to authenticated;
grant execute on function public.haversine_m(double precision, double precision, double precision, double precision) to authenticated;
