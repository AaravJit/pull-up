-- Reverts 20261016000100_core_identity.sql. DESTRUCTIVE for profiles; guarded.
-- auth.users rows are left alone: deleting accounts is not a schema rollback.
do $$
begin
  if exists (select 1 from public.profiles) and coalesce(current_setting('pullup.allow_destructive_rollback', true), '') <> 'on' then
    raise exception 'profiles exist; export them and set pullup.allow_destructive_rollback = on to proceed';
  end if;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
drop function if exists public.get_profile(uuid);
drop table if exists public.blocks;
drop table if exists public.follows;
drop table if exists public.privacy_settings;
drop table if exists public.profile_details;
drop table if exists public.profiles;
drop function if exists public.can_view(uuid, public.visibility);
drop function if exists public.is_friend(uuid, uuid);
drop function if exists public.is_blocked_between(uuid, uuid);
drop function if exists public.least_visibility(public.visibility, public.visibility);
drop function if exists private.handle_new_user();
drop function if exists private.follow_status();
drop function if exists private.apply_block();
drop function if exists private.protect_profile_columns();
drop function if exists private.touch_updated_at();
drop function if exists private.visibility_rank(public.visibility);
drop function if exists private.is_trusted();
drop type if exists public.visibility;
drop schema if exists private;
