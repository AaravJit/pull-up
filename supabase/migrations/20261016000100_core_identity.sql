-- Pull Up core: identity, privacy settings, follows, blocks, and the
-- visibility helpers every other policy builds on.
--
-- Conventions
--   * Every table has RLS enabled and policies scoped `to authenticated`.
--     Anonymous clients can read nothing.
--   * Security-definer functions pin `search_path = ''` and qualify names.
--   * Columns only the server may set are protected by
--     `private.protect_columns` triggers, not by trusting the client.
--   * Each migration has a matching script in supabase/rollback/.

create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to authenticated, service_role;

create type public.visibility as enum ('public', 'friends', 'private');

-- True when the statement runs as the server (service role, a migration, or
-- inside a security-definer function owned by postgres) rather than directly
-- as a signed-in client.
create or replace function private.is_trusted()
returns boolean
language sql
stable
set search_path = ''
as $$
  select current_user in ('postgres', 'service_role', 'supabase_admin');
$$;

create or replace function private.visibility_rank(v public.visibility)
returns int
language sql
immutable
set search_path = ''
as $$
  select case v when 'private' then 0 when 'friends' then 1 else 2 end;
$$;

create or replace function public.least_visibility(a public.visibility, b public.visibility)
returns public.visibility
language sql
immutable
set search_path = ''
as $$
  select case when private.visibility_rank(a) <= private.visibility_rank(b) then a else b end;
$$;

-- ---------------------------------------------------------------------------
-- Profiles
-- ---------------------------------------------------------------------------

-- Identity fields every signed-in user may see (so comments and attendee
-- lists can show a name). Anything more personal lives in profile_details.
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  username text not null unique
    check (username ~ '^[a-z0-9_.]{3,30}$'),
  display_name text not null default '' check (char_length(display_name) <= 60),
  avatar_path text,
  visibility public.visibility not null default 'public',
  presentation jsonb not null default '{"layout":"showcase","show_stats":true}'::jsonb,
  -- Set only by Pull Up staff. Track-day meets hosted by verified organisers
  -- are the only source of performance-leaderboard entries.
  is_verified_organizer boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.profile_details (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  bio text not null default '' check (char_length(bio) <= 280),
  -- ISO 3166-1 alpha-2 and ISO 3166-2, self-declared. Used for regional
  -- leaderboards. Never derived from GPS.
  country_code text check (country_code ~ '^[A-Z]{2}$'),
  region_code text check (region_code ~ '^[A-Z]{2}-[A-Z0-9]{1,3}$'),
  updated_at timestamptz not null default now()
);

create table public.privacy_settings (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  default_vehicle_visibility public.visibility not null default 'friends',
  -- Ceiling for every drive: a drive is never more visible than this.
  drive_history_visibility public.visibility not null default 'private',
  allow_route_sharing boolean not null default false,
  route_endpoint_trim_m integer not null default 400 check (route_endpoint_trim_m between 200 and 3000),
  show_event_attendance boolean not null default false,
  leaderboard_opt_in boolean not null default false,
  performance_leaderboard_opt_in boolean not null default false,
  require_follow_approval boolean not null default false,
  updated_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Graph
-- ---------------------------------------------------------------------------

create table public.follows (
  follower_id uuid not null references public.profiles (id) on delete cascade,
  followee_id uuid not null references public.profiles (id) on delete cascade,
  status text not null default 'accepted' check (status in ('accepted', 'pending')),
  created_at timestamptz not null default now(),
  primary key (follower_id, followee_id),
  check (follower_id <> followee_id)
);
create index follows_followee_idx on public.follows (followee_id, status);

create table public.blocks (
  blocker_id uuid not null references public.profiles (id) on delete cascade,
  blocked_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);
create index blocks_blocked_idx on public.blocks (blocked_id);

-- ---------------------------------------------------------------------------
-- Visibility helpers
-- ---------------------------------------------------------------------------

create or replace function public.is_blocked_between(a uuid, b uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.blocks
    where (blocker_id = a and blocked_id = b) or (blocker_id = b and blocked_id = a)
  );
$$;

-- Friends = mutual accepted follows.
create or replace function public.is_friend(a uuid, b uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.follows where follower_id = a and followee_id = b and status = 'accepted')
     and exists (select 1 from public.follows where follower_id = b and followee_id = a and status = 'accepted');
$$;

-- The one rule behind every read policy: may the current user see content
-- owned by `owner` at visibility `vis`? The owner's profile visibility acts
-- as a ceiling, so a private profile hides even "public" posts.
create or replace function public.can_view(owner uuid, vis public.visibility)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  viewer uuid := auth.uid();
  effective public.visibility;
begin
  if viewer is null then
    return false;
  end if;
  if owner = viewer then
    return true;
  end if;
  if public.is_blocked_between(owner, viewer) then
    return false;
  end if;
  select public.least_visibility(vis, p.visibility) into effective
  from public.profiles p where p.id = owner;
  if effective is null or effective = 'private' then
    return false;
  end if;
  if effective = 'friends' then
    return public.is_friend(owner, viewer);
  end if;
  return true;
end;
$$;

-- ---------------------------------------------------------------------------
-- Triggers
-- ---------------------------------------------------------------------------

create or replace function private.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger profiles_touch before update on public.profiles
  for each row execute function private.touch_updated_at();
create trigger profile_details_touch before update on public.profile_details
  for each row execute function private.touch_updated_at();
create trigger privacy_settings_touch before update on public.privacy_settings
  for each row execute function private.touch_updated_at();

create or replace function private.protect_profile_columns()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not private.is_trusted() then
    if tg_op = 'INSERT' then
      new.is_verified_organizer := false;
    else
      new.is_verified_organizer := old.is_verified_organizer;
      new.id := old.id;
    end if;
  end if;
  return new;
end;
$$;

create trigger profiles_protect before insert or update on public.profiles
  for each row execute function private.protect_profile_columns();

-- New auth user → profile, details and private-by-default settings.
create or replace function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  requested text := lower(coalesce(new.raw_user_meta_data ->> 'username', ''));
  candidate text;
begin
  if requested ~ '^[a-z0-9_.]{3,30}$' and not exists (select 1 from public.profiles where username = requested) then
    candidate := requested;
  else
    candidate := 'driver_' || substr(replace(new.id::text, '-', ''), 1, 10);
  end if;
  insert into public.profiles (id, username, display_name)
  values (new.id, candidate, coalesce(new.raw_user_meta_data ->> 'display_name', ''));
  insert into public.profile_details (user_id) values (new.id);
  insert into public.privacy_settings (user_id) values (new.id);
  return new;
end;
$$;

create trigger on_auth_user_created after insert on auth.users
  for each row execute function private.handle_new_user();

-- Following someone who requires approval creates a pending request.
create or replace function private.follow_status()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if public.is_blocked_between(new.follower_id, new.followee_id) then
      raise exception 'cannot follow this user' using errcode = '42501';
    end if;
    select case when ps.require_follow_approval then 'pending' else 'accepted' end
      into new.status
    from public.privacy_settings ps where ps.user_id = new.followee_id;
    new.status := coalesce(new.status, 'accepted');
  elsif tg_op = 'UPDATE' then
    -- Only the followee may accept; nobody may change the pair.
    if new.follower_id <> old.follower_id or new.followee_id <> old.followee_id then
      raise exception 'follow pair is immutable' using errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;

create trigger follows_status before insert or update on public.follows
  for each row execute function private.follow_status();

-- Blocking removes follows in both directions.
create or replace function private.apply_block()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.follows
  where (follower_id = new.blocker_id and followee_id = new.blocked_id)
     or (follower_id = new.blocked_id and followee_id = new.blocker_id);
  return new;
end;
$$;

create trigger blocks_apply after insert on public.blocks
  for each row execute function private.apply_block();

-- ---------------------------------------------------------------------------
-- Row-level security
-- ---------------------------------------------------------------------------

alter table public.profiles enable row level security;
alter table public.profile_details enable row level security;
alter table public.privacy_settings enable row level security;
alter table public.follows enable row level security;
alter table public.blocks enable row level security;

create policy "Profiles: identity visible to signed-in users unless blocked"
  on public.profiles for select to authenticated
  using (id = auth.uid() or not public.is_blocked_between(id, auth.uid()));
create policy "Profiles: owner updates"
  on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

create policy "Details: governed by profile visibility"
  on public.profile_details for select to authenticated
  using (public.can_view(user_id, 'public'));
create policy "Details: owner updates"
  on public.profile_details for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy "Privacy settings: owner only"
  on public.privacy_settings for select to authenticated
  using (user_id = auth.uid());
create policy "Privacy settings: owner updates"
  on public.privacy_settings for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy "Follows: parties, or accepted edges of visible profiles"
  on public.follows for select to authenticated
  using (
    follower_id = auth.uid() or followee_id = auth.uid()
    or (status = 'accepted' and public.can_view(followee_id, 'public') and public.can_view(follower_id, 'public'))
  );
create policy "Follows: follow as yourself"
  on public.follows for insert to authenticated
  with check (follower_id = auth.uid());
create policy "Follows: followee accepts"
  on public.follows for update to authenticated
  using (followee_id = auth.uid()) with check (followee_id = auth.uid() and status = 'accepted');
create policy "Follows: either party removes"
  on public.follows for delete to authenticated
  using (follower_id = auth.uid() or followee_id = auth.uid());

create policy "Blocks: own list"
  on public.blocks for select to authenticated using (blocker_id = auth.uid());
create policy "Blocks: block as yourself"
  on public.blocks for insert to authenticated with check (blocker_id = auth.uid());
create policy "Blocks: unblock"
  on public.blocks for delete to authenticated using (blocker_id = auth.uid());

-- Combined profile for a profile page. Details are null when not permitted.
create or replace function public.get_profile(p_user uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  result jsonb;
  can_see boolean := public.can_view(p_user, 'public');
begin
  if auth.uid() is null or (p_user <> auth.uid() and public.is_blocked_between(p_user, auth.uid())) then
    return null;
  end if;
  select jsonb_build_object(
    'id', p.id,
    'username', p.username,
    'display_name', p.display_name,
    'avatar_path', p.avatar_path,
    'visibility', p.visibility,
    'presentation', p.presentation,
    'is_verified_organizer', p.is_verified_organizer,
    'bio', case when can_see then d.bio else '' end,
    'country_code', case when can_see then d.country_code end,
    'region_code', case when can_see then d.region_code end,
    'can_view_content', can_see,
    'follower_count', (select count(*) from public.follows f where f.followee_id = p.id and f.status = 'accepted'),
    'following_count', (select count(*) from public.follows f where f.follower_id = p.id and f.status = 'accepted'),
    'relationship', jsonb_build_object(
      'i_follow', (select f.status from public.follows f where f.follower_id = auth.uid() and f.followee_id = p.id),
      'follows_me', (select f.status from public.follows f where f.follower_id = p.id and f.followee_id = auth.uid())
    )
  ) into result
  from public.profiles p
  join public.profile_details d on d.user_id = p.id
  where p.id = p_user;
  return result;
end;
$$;

grant execute on function public.get_profile(uuid) to authenticated;
grant execute on function public.can_view(uuid, public.visibility) to authenticated;
grant execute on function public.is_friend(uuid, uuid) to authenticated;
revoke execute on function public.get_profile(uuid) from anon;
