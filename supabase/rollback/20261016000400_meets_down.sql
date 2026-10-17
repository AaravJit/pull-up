-- Reverts 20261016000400_meets.sql. DESTRUCTIVE for meets and RSVPs; guarded.
do $$
begin
  if exists (select 1 from public.meets) and coalesce(current_setting('pullup.allow_destructive_rollback', true), '') <> 'on' then
    raise exception 'meets exist; export them and set pullup.allow_destructive_rollback = on to proceed';
  end if;
end $$;
drop function if exists public.attach_drive_to_track_event(uuid, uuid);
alter table public.drives drop constraint if exists drives_closed_course_meet_fk;
drop function if exists public.meet_attendees(uuid);
drop function if exists public.going_count(public.meets);
drop function if exists public.interested_count(public.meets);
drop function if exists public.my_rsvp(public.meets);
drop table if exists public.meet_rsvps;
drop table if exists public.meets;
drop function if exists public.can_view_meet(uuid);
drop function if exists public.is_attending(uuid);
drop function if exists private.guard_rsvp();
drop function if exists private.rsvp_default_visibility();
