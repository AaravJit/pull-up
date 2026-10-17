-- Reverts 20261016000500_social.sql.
-- DESTRUCTIVE: drops posts, comments, likes, notifications and device tokens.
-- Refuses to run against a database that holds posts unless
-- `set pullup.allow_destructive_rollback = 'on'` was issued first.
do $$
begin
  if exists (select 1 from public.posts) and coalesce(current_setting('pullup.allow_destructive_rollback', true), '') <> 'on' then
    raise exception 'posts exist; export them and set pullup.allow_destructive_rollback = on to proceed';
  end if;
end $$;
drop trigger if exists rsvps_notify on public.meet_rsvps;
drop trigger if exists meets_notify on public.meets;
drop trigger if exists follows_notify on public.follows;
drop table if exists public.device_tokens;
drop table if exists public.notifications;
drop table if exists public.comments;
drop table if exists public.likes;
drop table if exists public.post_media;
drop table if exists public.posts cascade;
drop function if exists public.home_feed(timestamptz, integer);
drop function if exists public.can_view_post(uuid);
drop function if exists private.guard_post();
drop function if exists private.notify(uuid, uuid, text, uuid, uuid);
drop function if exists private.on_follow();
drop function if exists private.on_like();
drop function if exists private.on_comment();
drop function if exists private.on_rsvp();
drop function if exists private.on_meet_change();
