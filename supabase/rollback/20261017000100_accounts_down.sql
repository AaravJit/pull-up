-- Reverts 20261017000100_accounts.sql. Dropping onboarded_at loses who has
-- finished onboarding, so it is guarded like the other destructive rollbacks.
do $$
begin
  if exists (select 1 from public.profiles where onboarded_at is not null)
     and coalesce(current_setting('pullup.allow_destructive_rollback', true), '') <> 'on' then
    raise exception 'onboarding state exists; set pullup.allow_destructive_rollback = on to drop it';
  end if;
end $$;

drop trigger if exists pullup_identity_link_guard on auth.identities;
drop function if exists private.guard_identity_link();
drop function if exists public.begin_identity_link(text);
drop table if exists private.identity_link_intents;
drop function if exists public.complete_onboarding();
drop function if exists public.claim_username(text, text);
drop function if exists public.username_status(text);
drop trigger if exists profiles_identity on public.profiles;
drop function if exists private.guard_profile_identity();

-- Restore the previous definitions from 20261016000100_core_identity.sql.
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

drop function if exists private.username_problem(text, uuid);
drop table if exists private.reserved_usernames;
alter table public.profiles drop column if exists onboarded_at;
