-- Accounts: first-run onboarding, username rules, and the guard that stops
-- Supabase Auth from merging two accounts just because their emails match.
--
-- Sign in with Apple creates the auth user with no username, so
-- handle_new_user gives it a placeholder (`driver_<10 hex>`). Onboarding then
-- claims a real one through claim_username and finishes with
-- complete_onboarding, which is what sets onboarded_at.

alter table public.profiles add column onboarded_at timestamptz;

-- Accounts that chose a username at sign-up (email, before this migration)
-- have effectively onboarded. Placeholder names go through onboarding.
update public.profiles set onboarded_at = created_at
where onboarded_at is null and username !~ '^driver_[0-9a-f]{10}$';

-- ---------------------------------------------------------------------------
-- Username rules
-- ---------------------------------------------------------------------------

-- Names nobody may claim, because they would read as Pull Up staff, a
-- platform, or a placeholder. `prefix` rows also block anything starting
-- with the name.
create table private.reserved_usernames (
  name text primary key,
  prefix boolean not null default false
);
insert into private.reserved_usernames (name, prefix) values
  ('pullup', true), ('pull.up', true), ('pull_up', true), ('driver_', true),
  ('admin', false), ('administrator', false), ('root', false), ('support', false),
  ('help', false), ('staff', false), ('team', false), ('moderator', false),
  ('mod', false), ('mods', false), ('official', false), ('verified', false),
  ('security', false), ('safety', false), ('system', false), ('api', false),
  ('www', false), ('app', false), ('apple', false), ('google', false),
  ('ebay', false), ('null', false), ('undefined', false), ('everyone', false),
  ('settings', false), ('me', false), ('you', false), ('anonymous', false);

-- Why `candidate` can't be `self`'s username, or null when it can.
-- Format rules match the column check plus: no leading, trailing or
-- doubled separators, so names stay readable.
create or replace function private.username_problem(candidate text, self uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when candidate is null or candidate !~ '^[a-z0-9_.]{3,30}$' then 'format'
    when candidate ~ '^[._]|[._]$|[._]{2}' then 'format'
    when exists (
      select 1 from private.reserved_usernames r
      where candidate = r.name or (r.prefix and starts_with(candidate, r.name))
    ) then 'reserved'
    when exists (select 1 from public.profiles p where p.username = candidate and p.id is distinct from self) then 'taken'
  end;
$$;

-- Every username change by a client goes through the same rules, whether it
-- comes from claim_username or a direct profile update. Security invoker on
-- purpose: is_trusted() looks at current_user, which a definer would mask.
create or replace function private.guard_profile_identity()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  problem text;
begin
  if tg_op = 'UPDATE' and new.username is distinct from old.username and not private.is_trusted() then
    problem := private.username_problem(new.username, new.id);
    if problem is not null then
      raise exception 'username %', problem using errcode = case when problem = 'taken' then '23505' else '22023' end;
    end if;
  end if;
  -- An avatar must be a file in the owner's own avatars folder.
  if new.avatar_path is not null and split_part(new.avatar_path, '/', 1) <> new.id::text then
    raise exception 'avatar must be in your own folder' using errcode = '42501';
  end if;
  return new;
end;
$$;

create trigger profiles_identity before insert or update on public.profiles
  for each row execute function private.guard_profile_identity();

-- onboarded_at is set only by complete_onboarding.
create or replace function private.protect_profile_columns()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not private.is_trusted() then
    if tg_op = 'INSERT' then
      new.is_verified_organizer := false;
      new.onboarded_at := null;
    else
      new.is_verified_organizer := old.is_verified_organizer;
      new.onboarded_at := old.onboarded_at;
      new.id := old.id;
    end if;
  end if;
  return new;
end;
$$;

-- New auth user: the requested username is used only if it passes every
-- rule; otherwise a placeholder that onboarding replaces.
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
  if private.username_problem(requested, new.id) is null then
    candidate := requested;
  else
    candidate := 'driver_' || substr(replace(new.id::text, '-', ''), 1, 10);
  end if;
  insert into public.profiles (id, username, display_name)
  values (new.id, candidate, left(coalesce(new.raw_user_meta_data ->> 'display_name', ''), 60));
  insert into public.profile_details (user_id) values (new.id);
  insert into public.privacy_settings (user_id) values (new.id);
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Onboarding RPCs
-- ---------------------------------------------------------------------------

-- Live availability check while typing. Usernames are already visible to
-- every signed-in user, so this reveals nothing new.
create or replace function public.username_status(p_username text)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'sign in first' using errcode = '42501';
  end if;
  return coalesce(private.username_problem(lower(trim(p_username)), auth.uid()), 'available');
end;
$$;

create or replace function public.claim_username(p_username text, p_display_name text default '')
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  wanted text := lower(trim(p_username));
  problem text;
begin
  if me is null then
    raise exception 'sign in first' using errcode = '42501';
  end if;
  problem := private.username_problem(wanted, me);
  if problem is not null then
    raise exception 'username %', problem using errcode = case when problem = 'taken' then '23505' else '22023' end;
  end if;
  begin
    update public.profiles
    set username = wanted, display_name = left(trim(coalesce(p_display_name, '')), 60)
    where id = me;
  exception when unique_violation then
    -- Someone claimed it between the check and the update.
    raise exception 'username taken' using errcode = '23505';
  end;
  return wanted;
end;
$$;

create or replace function public.complete_onboarding()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
begin
  if me is null then
    raise exception 'sign in first' using errcode = '42501';
  end if;
  if exists (select 1 from public.profiles where id = me and username ~ '^driver_[0-9a-f]{10}$') then
    raise exception 'choose a username first' using errcode = '22023';
  end if;
  update public.profiles set onboarded_at = coalesce(onboarded_at, now()) where id = me;
end;
$$;

-- ---------------------------------------------------------------------------
-- Account linking
-- ---------------------------------------------------------------------------
--
-- Supabase Auth links a new sign-in method to an existing user whenever the
-- verified emails match. Pull Up does not accept that on its own: a second
-- method (say Google on Android) is attached only when the signed-in user
-- asked for it within the last ten minutes, via begin_identity_link, and then
-- completes the provider's own sign-in. Anything else is refused, and the
-- person is told to sign in the way they did before.

create table private.identity_link_intents (
  user_id uuid not null references auth.users (id) on delete cascade,
  provider text not null check (provider in ('apple', 'google', 'email')),
  created_at timestamptz not null default now(),
  primary key (user_id, provider)
);

create or replace function public.begin_identity_link(p_provider text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'sign in first' using errcode = '42501';
  end if;
  insert into private.identity_link_intents (user_id, provider) values (auth.uid(), p_provider)
  on conflict (user_id, provider) do update set created_at = now();
end;
$$;

create or replace function private.guard_identity_link()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (select 1 from auth.identities i where i.user_id = new.user_id and i.provider <> new.provider) then
    delete from private.identity_link_intents
    where user_id = new.user_id and provider = new.provider and created_at > now() - interval '10 minutes';
    if not found then
      raise exception 'automatic account linking is disabled: sign in with your existing method, then add % from Settings', new.provider
        using errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;

-- Hosted projects normally allow triggers on auth tables (handle_new_user is
-- one). If this project doesn't, the migration still applies and says so;
-- RELEASE_CHECKLIST.md has the check to run after `db push`.
do $$
begin
  create trigger pullup_identity_link_guard before insert on auth.identities
    for each row execute function private.guard_identity_link();
exception when insufficient_privilege then
  raise warning 'pullup_identity_link_guard was not installed (%). Automatic linking by email is NOT blocked.', sqlerrm;
end $$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------

revoke execute on function public.username_status(text) from public, anon;
revoke execute on function public.claim_username(text, text) from public, anon;
revoke execute on function public.complete_onboarding() from public, anon;
revoke execute on function public.begin_identity_link(text) from public, anon;
grant execute on function public.username_status(text) to authenticated;
grant execute on function public.claim_username(text, text) to authenticated;
grant execute on function public.complete_onboarding() to authenticated;
grant execute on function public.begin_identity_link(text) to authenticated;
