-- Reverts 20261016000200_garage.sql. DESTRUCTIVE for vehicles; guarded.
do $$
begin
  if exists (select 1 from public.vehicles) and coalesce(current_setting('pullup.allow_destructive_rollback', true), '') <> 'on' then
    raise exception 'vehicles exist; export them and set pullup.allow_destructive_rollback = on to proceed';
  end if;
end $$;
drop table if exists public.vehicle_photos;
drop table if exists public.vehicle_mods;
drop table if exists public.vehicles;
drop function if exists public.can_view_vehicle(uuid);
drop function if exists public.owns_vehicle(uuid);
drop function if exists private.guard_vehicle();
drop type if exists public.vehicle_kind;
