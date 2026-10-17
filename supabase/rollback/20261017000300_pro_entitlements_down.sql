-- Reverts 20261017000300_pro_entitlements.sql. DESTRUCTIVE for paid
-- entitlements; guarded. Subscriptions themselves live with Apple and are
-- unaffected: re-applying the migration and having people open the app (or
-- the next App Store notification) records them again.
do $$
begin
  if exists (select 1 from public.entitlements)
     and coalesce(current_setting('pullup.allow_destructive_rollback', true), '') <> 'on' then
    raise exception 'entitlements exist; export them and set pullup.allow_destructive_rollback = on to proceed';
  end if;
end $$;

drop function if exists public.apply_entitlement(uuid, text, text, public.entitlement_status, timestamptz,
  timestamptz, boolean, text, timestamptz);
drop function if exists public.my_entitlement();
drop function if exists private.has_pro(uuid);
drop function if exists private.entitlement_grants(public.entitlement_status, timestamptz, timestamptz);
drop table if exists public.app_store_notifications;
drop table if exists public.entitlements;
drop type if exists public.entitlement_status;
