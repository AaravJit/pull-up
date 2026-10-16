-- Reverts 20261016000300_drives.sql. DESTRUCTIVE for drives and tracks; guarded.
do $$
begin
  if exists (select 1 from public.drives) and coalesce(current_setting('pullup.allow_destructive_rollback', true), '') <> 'on' then
    raise exception 'drives exist; export them and set pullup.allow_destructive_rollback = on to proceed';
  end if;
end $$;
drop trigger if exists privacy_settings_withdraw on public.privacy_settings;
drop function if exists private.withdraw_routes_when_sharing_disabled();
drop table if exists public.privacy_zones;
drop table if exists public.drive_shared_routes;
drop table if exists public.drive_tracks;
drop table if exists public.drives;
drop function if exists public.share_drive_route(uuid);
drop function if exists public.unshare_drive_route(uuid);
drop function if exists private.build_shared_route(uuid);
drop function if exists private.reshare_after_zone_change();
drop function if exists private.validate_drive(uuid);
drop function if exists private.after_track_insert();
drop function if exists private.guard_track();
drop function if exists private.guard_drive();
drop function if exists public.can_view_drive(uuid);
drop function if exists public.drive_history_ceiling(uuid);
drop function if exists public.haversine_m(double precision, double precision, double precision, double precision);
