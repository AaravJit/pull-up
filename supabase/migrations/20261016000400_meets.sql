-- Meets, cruises, rides, shows and track days, with RSVPs.
--
-- Attendance privacy
--   * An RSVP is visible to its owner.
--   * Other people see an RSVP only if its owner opted in (show_me) AND the
--     viewer is going to the same meet, or hosts it.
--   * Everyone who can see the meet sees aggregate counts only.
--   * RSVPs never carry the attendee's location.

create table public.meets (
  id uuid primary key default gen_random_uuid(),
  host_id uuid not null references public.profiles (id) on delete cascade,
  title text not null check (char_length(title) between 3 and 80),
  details text not null default '' check (char_length(details) <= 4000),
  kind text not null default 'meet' check (kind in ('meet', 'cruise', 'ride', 'show', 'track_day')),
  focus text not null default 'all' check (focus in ('all', 'cars', 'motorcycles')),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  venue_name text not null check (char_length(venue_name) between 1 and 120),
  address text not null default '',
  lat double precision not null check (lat between -90 and 90),
  lon double precision not null check (lon between -180 and 180),
  visibility public.visibility not null default 'public' check (visibility <> 'private'),
  capacity integer check (capacity > 0),
  cancelled_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (ends_at > starts_at),
  check (ends_at - starts_at <= interval '4 days')
);
create index meets_starts_idx on public.meets (starts_at) where cancelled_at is null;
create index meets_geo_idx on public.meets (lat, lon);

create table public.meet_rsvps (
  meet_id uuid not null references public.meets (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  status text not null check (status in ('going', 'interested')),
  -- No column default: when the client omits it, the user's
  -- show_event_attendance setting decides (see rsvp_default_visibility).
  show_me boolean not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (meet_id, user_id)
);
create index meet_rsvps_user_idx on public.meet_rsvps (user_id);

alter table public.drives
  add constraint drives_closed_course_meet_fk
  foreign key (closed_course_meet_id) references public.meets (id) on delete set null;

create trigger meets_touch before update on public.meets
  for each row execute function private.touch_updated_at();
create trigger meet_rsvps_touch before update on public.meet_rsvps
  for each row execute function private.touch_updated_at();

create or replace function public.can_view_meet(p_meet uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.meets m where m.id = p_meet and public.can_view(m.host_id, m.visibility));
$$;

create or replace function public.is_attending(p_meet uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.meet_rsvps r where r.meet_id = p_meet and r.user_id = auth.uid() and r.status = 'going')
      or exists (select 1 from public.meets m where m.id = p_meet and m.host_id = auth.uid());
$$;

-- Capacity, cancellation and default show_me. Locks the meet row so two
-- last-minute RSVPs can't both take the final spot.
create or replace function private.guard_rsvp()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  m public.meets;
  going integer;
begin
  select * into m from public.meets where id = new.meet_id for update;
  if m.cancelled_at is not null then
    raise exception 'meet is cancelled' using errcode = '22023';
  end if;
  if m.ends_at < now() then
    raise exception 'meet has ended' using errcode = '22023';
  end if;
  if new.status = 'going' and m.capacity is not null and (tg_op = 'INSERT' or old.status <> 'going') then
    select count(*) into going from public.meet_rsvps where meet_id = new.meet_id and status = 'going';
    if going >= m.capacity then
      raise exception 'meet is full' using errcode = '23514';
    end if;
  end if;
  if tg_op = 'UPDATE' and (new.meet_id <> old.meet_id or new.user_id <> old.user_id) then
    raise exception 'rsvp identity is immutable' using errcode = '42501';
  end if;
  return new;
end;
$$;

create trigger meet_rsvps_guard before insert or update on public.meet_rsvps
  for each row execute function private.guard_rsvp();

-- Default show_me from the user's privacy setting when the client omits it.
create or replace function private.rsvp_default_visibility()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.show_me is null then
    select coalesce(ps.show_event_attendance, false) into new.show_me
    from public.privacy_settings ps where ps.user_id = new.user_id;
    new.show_me := coalesce(new.show_me, false);
  end if;
  return new;
end;
$$;

create trigger meet_rsvps_default before insert on public.meet_rsvps
  for each row execute function private.rsvp_default_visibility();

-- Computed columns for PostgREST: select=*,going_count,interested_count,my_rsvp
create or replace function public.going_count(m public.meets)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::int from public.meet_rsvps r where r.meet_id = m.id and r.status = 'going';
$$;

create or replace function public.interested_count(m public.meets)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::int from public.meet_rsvps r where r.meet_id = m.id and r.status = 'interested';
$$;

create or replace function public.my_rsvp(m public.meets)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object('status', r.status, 'show_me', r.show_me)
  from public.meet_rsvps r where r.meet_id = m.id and r.user_id = auth.uid();
$$;

-- Attendees the viewer is allowed to see.
create or replace function public.meet_attendees(p_meet uuid)
returns table (id uuid, username text, display_name text, avatar_path text, status text)
language sql
stable
security definer
set search_path = ''
as $$
  select p.id, p.username, p.display_name, p.avatar_path, r.status
  from public.meet_rsvps r
  join public.profiles p on p.id = r.user_id
  where r.meet_id = p_meet
    and public.can_view_meet(p_meet)
    and (r.user_id = auth.uid() or (r.show_me and public.is_attending(p_meet)))
    and not public.is_blocked_between(r.user_id, auth.uid())
  order by r.created_at;
$$;

alter table public.meets enable row level security;
alter table public.meet_rsvps enable row level security;

create policy "Meets: visible per host and visibility"
  on public.meets for select to authenticated using (public.can_view(host_id, visibility));
create policy "Meets: host creates"
  on public.meets for insert to authenticated with check (host_id = auth.uid() and starts_at > now() - interval '1 hour');
create policy "Meets: host edits"
  on public.meets for update to authenticated using (host_id = auth.uid()) with check (host_id = auth.uid());
create policy "Meets: host deletes"
  on public.meets for delete to authenticated using (host_id = auth.uid());

create policy "RSVPs: own, or opted-in attendees for fellow attendees"
  on public.meet_rsvps for select to authenticated
  using (user_id = auth.uid() or (show_me and public.is_attending(meet_id) and public.can_view_meet(meet_id)));
create policy "RSVPs: RSVP as yourself to a meet you can see"
  on public.meet_rsvps for insert to authenticated
  with check (user_id = auth.uid() and public.can_view_meet(meet_id));
create policy "RSVPs: change your own"
  on public.meet_rsvps for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "RSVPs: cancel your own"
  on public.meet_rsvps for delete to authenticated using (user_id = auth.uid());

grant execute on function public.meet_attendees(uuid) to authenticated;
grant execute on function public.can_view_meet(uuid) to authenticated;
grant execute on function public.is_attending(uuid) to authenticated;
grant execute on function public.going_count(public.meets) to authenticated;
grant execute on function public.interested_count(public.meets) to authenticated;
grant execute on function public.my_rsvp(public.meets) to authenticated;

-- Closed-course attachment: the only path into performance leaderboards.
create or replace function public.attach_drive_to_track_event(p_drive uuid, p_meet uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  d public.drives;
  m public.meets;
  first_lat double precision;
  first_lon double precision;
begin
  select * into d from public.drives where id = p_drive;
  if d.id is null or d.owner_id <> auth.uid() then
    raise exception 'not your drive' using errcode = '42501';
  end if;
  select * into m from public.meets where id = p_meet;
  if m.id is null or m.kind <> 'track_day' or m.cancelled_at is not null then
    raise exception 'not a track day' using errcode = '22023';
  end if;
  if not exists (select 1 from public.profiles where id = m.host_id and is_verified_organizer) then
    raise exception 'track day organiser is not verified' using errcode = '42501';
  end if;
  if not exists (select 1 from public.meet_rsvps where meet_id = p_meet and user_id = auth.uid() and status = 'going') then
    raise exception 'you were not registered for this track day' using errcode = '42501';
  end if;
  if d.started_at < m.starts_at - interval '1 hour' or d.ended_at > m.ends_at + interval '1 hour' then
    raise exception 'drive is outside the event window' using errcode = '22023';
  end if;
  select (points -> 0 ->> 1)::float8, (points -> 0 ->> 2)::float8 into first_lat, first_lon
  from public.drive_tracks where drive_id = p_drive;
  if first_lat is null or public.haversine_m(first_lat, first_lon, m.lat, m.lon) > 3000 then
    raise exception 'drive did not start at the venue' using errcode = '22023';
  end if;
  update public.drives set closed_course_meet_id = p_meet where id = p_drive;
end;
$$;

grant execute on function public.attach_drive_to_track_event(uuid, uuid) to authenticated;
