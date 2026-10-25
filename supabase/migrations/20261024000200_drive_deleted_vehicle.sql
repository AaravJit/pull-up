-- A drive recorded against a vehicle that was deleted before the drive
-- uploaded (it waited on the phone, offline) was refused with "vehicle does
-- not belong to the driver" (42501), so the app retried it forever. A drive
-- already stored loses its vehicle when the vehicle is deleted (on delete
-- set null); guard_drive now does the same for one written afterwards, and
-- keeps it as a guest drive. A vehicle that exists but belongs to someone
-- else is still refused.
--
-- The vehicle is looked up as the writer sees it (row level security), as
-- before: a vehicle hidden from them counts as deleted, so the drive is
-- stored without it and the answer doesn't reveal whether someone else's
-- private vehicle exists. The drive is never attached to it either way.
--
-- Reversible: supabase/rollback/20261024000200_drive_deleted_vehicle_down.sql
-- restores the previous definition. No data is touched.

create or replace function private.guard_drive()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not private.is_trusted() then
    if tg_op = 'INSERT' then
      new.validation_status := 'pending';
      new.validation_notes := '{}';
      new.server_distance_m := null;
      new.server_top_speed_mps := null;
      new.explored_cells := '{}';
      new.closed_course_meet_id := null;
      new.has_shared_route := false;
    else
      if new.owner_id <> old.owner_id then
        raise exception 'drive owner is immutable' using errcode = '42501';
      end if;
      -- Statistics are frozen once submitted; only presentation may change.
      new.started_at := old.started_at;
      new.ended_at := old.ended_at;
      new.distance_m := old.distance_m;
      new.moving_s := old.moving_s;
      new.stopped_s := old.stopped_s;
      new.elapsed_s := old.elapsed_s;
      new.top_speed_mps := old.top_speed_mps;
      new.avg_moving_speed_mps := old.avg_moving_speed_mps;
      new.elevation_gain_m := old.elevation_gain_m;
      new.elevation_loss_m := old.elevation_loss_m;
      new.zero_to_sixty_s := old.zero_to_sixty_s;
      new.zero_to_sixty_quality := old.zero_to_sixty_quality;
      new.validation_status := old.validation_status;
      new.validation_notes := old.validation_notes;
      new.server_distance_m := old.server_distance_m;
      new.server_top_speed_mps := old.server_top_speed_mps;
      new.explored_cells := old.explored_cells;
      new.closed_course_meet_id := old.closed_course_meet_id;
      new.has_shared_route := old.has_shared_route;
    end if;
  end if;
  if new.vehicle_id is not null then
    if not exists (select 1 from public.vehicles v where v.id = new.vehicle_id) then
      -- Deleted: the drive is kept as a guest drive, as on delete set null
      -- does for drives already stored.
      new.vehicle_id := null;
    elsif not exists (
      select 1 from public.vehicles v where v.id = new.vehicle_id and v.owner_id = new.owner_id
    ) then
      raise exception 'vehicle does not belong to the driver' using errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;
