-- Reverts 20261024000200_drive_deleted_vehicle.sql: guard_drive as defined
-- in 20261016000300_drives.sql. No data is touched.

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
  if new.vehicle_id is not null and not exists (
    select 1 from public.vehicles v where v.id = new.vehicle_id and v.owner_id = new.owner_id
  ) then
    raise exception 'vehicle does not belong to the driver' using errcode = '42501';
  end if;
  return new;
end;
$$;
