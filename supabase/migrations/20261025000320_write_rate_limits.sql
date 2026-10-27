-- Moderation, part 3: per-account rate limits on the write paths that had
-- none, enforced in the database so the REST API can't skip them.
--
-- Each limit is a BEFORE INSERT trigger that takes a slot from
-- public.take_function_slot (20261018000200), the log the edge functions
-- already use: a write is refused with SQLSTATE 54000 once the account has
-- made the per-minute or per-hour number of that kind of write. Deleting
-- what you wrote doesn't give a slot back, so post/delete or
-- follow/unfollow loops are limited too. Writes by the server (no signed-in
-- user) aren't limited.
--
--   posts            5 a minute,  30 an hour
--   comments        10 a minute, 100 an hour
--   meets            3 a minute,  10 an hour
--   meet RSVPs      20 a minute, 100 an hour
--   follows         30 a minute, 200 an hour
--   likes           60 a minute, 500 an hour
--   vehicles         5 a minute,  20 an hour
--   vehicle mods    30 a minute, 200 an hour
--   vehicle photos  30 a minute, 200 an hour
--   message reactions 60 a minute, 500 an hour
--   messages        60 a minute, 600 an hour (the 30 a minute in
--                   guard_message, 20261017000200, still applies first)
-- Reports: 5 a minute and 15 an hour in report_user (20261025000310), on
-- top of 20 a day. New conversations: 20 a day (start_conversation).
--
-- Reversible: supabase/rollback/20261025000320_write_rate_limits_down.sql.

create or replace function private.take_write_slot()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
begin
  if me is null then
    return new;
  end if;
  if not public.take_function_slot(me, 'write:' || tg_argv[0], tg_argv[1]::integer, tg_argv[2]::integer) then
    raise exception 'You''re doing that a lot. Wait a few minutes and try again.'
      using errcode = '54000', detail = 'rate limit: ' || tg_argv[0];
  end if;
  return new;
end;
$$;

revoke execute on function private.take_write_slot() from public, anon, authenticated;

create trigger posts_rate_limit before insert on public.posts
  for each row execute function private.take_write_slot('posts', '5', '30');
create trigger comments_rate_limit before insert on public.comments
  for each row execute function private.take_write_slot('comments', '10', '100');
create trigger meets_rate_limit before insert on public.meets
  for each row execute function private.take_write_slot('meets', '3', '10');
create trigger meet_rsvps_rate_limit before insert on public.meet_rsvps
  for each row execute function private.take_write_slot('meet_rsvps', '20', '100');
create trigger follows_rate_limit before insert on public.follows
  for each row execute function private.take_write_slot('follows', '30', '200');
create trigger likes_rate_limit before insert on public.likes
  for each row execute function private.take_write_slot('likes', '60', '500');
create trigger vehicles_rate_limit before insert on public.vehicles
  for each row execute function private.take_write_slot('vehicles', '5', '20');
create trigger vehicle_mods_rate_limit before insert on public.vehicle_mods
  for each row execute function private.take_write_slot('vehicle_mods', '30', '200');
create trigger vehicle_photos_rate_limit before insert on public.vehicle_photos
  for each row execute function private.take_write_slot('vehicle_photos', '30', '200');
create trigger message_reactions_rate_limit before insert on public.message_reactions
  for each row execute function private.take_write_slot('message_reactions', '60', '500');
create trigger messages_rate_limit before insert on public.messages
  for each row execute function private.take_write_slot('messages', '60', '600');
