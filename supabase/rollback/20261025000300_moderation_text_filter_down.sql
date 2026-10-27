-- Reverts 20261025000300_moderation_text_filter.sql: the filter triggers,
-- the matcher and the term list go; username_problem and handle_new_user
-- return to their 20261017000100 definitions. The term list is lost, so
-- export it first (select * from private.moderation_terms) if it matters.
-- Reverse 20261025000310 first: its audit trigger sits on the term list.

do $$
begin
  if to_regclass('private.moderation_terms') is not null
     and exists (select 1 from private.moderation_terms)
     and coalesce(current_setting('pullup.allow_destructive_rollback', true), '') <> 'on' then
    raise exception 'moderation terms exist; export them and set pullup.allow_destructive_rollback = on to proceed';
  end if;
end $$;

alter table public.profiles drop constraint if exists profiles_presentation_size;
alter table public.meets drop constraint if exists meets_address_length;
alter table public.vehicle_mods drop constraint if exists vehicle_mods_brand_length;

drop trigger if exists profiles_moderation_filter on public.profiles;
drop trigger if exists profile_details_moderation_filter on public.profile_details;
drop trigger if exists vehicles_moderation_filter on public.vehicles;
drop trigger if exists vehicle_mods_moderation_filter on public.vehicle_mods;
drop trigger if exists posts_moderation_filter on public.posts;
drop trigger if exists comments_moderation_filter on public.comments;
drop trigger if exists meets_moderation_filter on public.meets;
drop trigger if exists messages_moderation_filter on public.messages;
drop trigger if exists drives_moderation_filter on public.drives;

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

drop function if exists private.moderation_filter_drive_title();
drop function if exists private.moderation_filter_text();
drop function if exists private.moderation_match(text);
drop table if exists private.moderation_terms;
drop function if exists private.moderation_collapse(text);
drop function if exists private.moderation_fold(text);
