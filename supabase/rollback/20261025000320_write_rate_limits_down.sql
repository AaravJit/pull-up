-- Reverts 20261025000320_write_rate_limits.sql. Only the limits' log
-- entries (at most an hour old) are left behind; take_function_slot
-- removes them as it goes.

drop trigger if exists posts_rate_limit on public.posts;
drop trigger if exists comments_rate_limit on public.comments;
drop trigger if exists meets_rate_limit on public.meets;
drop trigger if exists meet_rsvps_rate_limit on public.meet_rsvps;
drop trigger if exists follows_rate_limit on public.follows;
drop trigger if exists likes_rate_limit on public.likes;
drop trigger if exists vehicles_rate_limit on public.vehicles;
drop trigger if exists vehicle_mods_rate_limit on public.vehicle_mods;
drop trigger if exists vehicle_photos_rate_limit on public.vehicle_photos;
drop trigger if exists message_reactions_rate_limit on public.message_reactions;
drop trigger if exists messages_rate_limit on public.messages;
drop function if exists private.take_write_slot();
