-- Pull Up Pro: subscription entitlements, written only by the server.
--
-- Security model
--   * The app never writes an entitlement. It sends a StoreKit transaction to
--     the verify-subscription function, which asks Apple's App Store Server
--     API for the subscription's real state and records it here with the
--     service role. App Store Server Notifications (app-store-notifications)
--     keep it current: renewals, grace period, billing retry, expiry, refunds
--     and revocations.
--   * A subscription is bound to the Pull Up account whose id was attached
--     to the purchase as Apple's appAccountToken. One Apple subscription can
--     never unlock two Pull Up accounts, and nothing is moved between
--     accounts automatically.
--   * People can read only their own entitlement, through RLS or
--     my_entitlement(). Whether someone else is Pro is not exposed.
--   * Nothing that is free today depends on this table.

create type public.entitlement_status as enum ('active', 'grace_period', 'billing_retry', 'expired', 'revoked');

create table public.entitlements (
  user_id uuid primary key references auth.users (id) on delete cascade,
  product_id text not null check (product_id in ('app.pullup.pro.monthly', 'app.pullup.pro.yearly')),
  -- Apple's id for the subscription across renewals. Unique, so one
  -- subscription belongs to at most one account.
  original_transaction_id text not null unique check (length(original_transaction_id) between 1 and 64),
  status public.entitlement_status not null,
  expires_at timestamptz,
  grace_expires_at timestamptz,
  auto_renew boolean not null default true,
  environment text not null check (environment in ('Production', 'Sandbox')),
  -- signedDate of the Apple data this row reflects; older data is ignored,
  -- since notifications can arrive out of order.
  signed_at timestamptz not null,
  updated_at timestamptz not null default now()
);

alter table public.entitlements enable row level security;

create policy "Entitlements: read your own" on public.entitlements
  for select to authenticated using (user_id = (select auth.uid()));

revoke insert, update, delete, truncate on public.entitlements from anon, authenticated;

-- App Store Server Notifications already handled, so Apple's retries are
-- no-ops. Holds Apple ids only. Service role only.
create table public.app_store_notifications (
  notification_uuid text primary key check (length(notification_uuid) between 1 and 64),
  notification_type text not null,
  subtype text,
  original_transaction_id text,
  environment text,
  received_at timestamptz not null default now()
);

alter table public.app_store_notifications enable row level security;
revoke all on public.app_store_notifications from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Rules
-- ---------------------------------------------------------------------------

create or replace function private.entitlement_grants(
  p_status public.entitlement_status, p_expires_at timestamptz, p_grace_expires_at timestamptz)
returns boolean
language sql
stable
set search_path = ''
as $$
  select case p_status
    when 'active' then p_expires_at is null or p_expires_at > now()
    when 'grace_period' then coalesce(p_grace_expires_at, p_expires_at) > now()
    else false
  end;
$$;

-- For server-side Pro features. Not callable by clients, so it can't be used
-- to find out who subscribes.
create or replace function private.has_pro(p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((
    select private.entitlement_grants(e.status, e.expires_at, e.grace_expires_at)
    from public.entitlements e where e.user_id = p_user
  ), false);
$$;

revoke execute on function private.has_pro(uuid) from public, anon, authenticated;

-- The caller's own entitlement. Always one row; is_pro is computed with the
-- server's clock, never the phone's.
create or replace function public.my_entitlement()
returns table (
  is_pro boolean, status text, product_id text, expires_at timestamptz,
  grace_expires_at timestamptz, auto_renew boolean, environment text)
language sql
stable
security invoker
set search_path = ''
as $$
  select
    coalesce(private.entitlement_grants(e.status, e.expires_at, e.grace_expires_at), false),
    e.status::text, e.product_id, e.expires_at, e.grace_expires_at, e.auto_renew, e.environment
  from (select 1) as one
  left join public.entitlements e on e.user_id = (select auth.uid());
$$;

revoke execute on function public.my_entitlement() from public, anon;
grant execute on function public.my_entitlement() to authenticated;

-- Records Apple's view of one subscription for one account. Called by the
-- verify-subscription and app-store-notifications functions only, after
-- they have fetched the state from Apple and checked appAccountToken.
-- Returns 'applied', 'stale' (older than what's stored) or 'kept_existing'
-- (the account already has a different subscription that still grants Pro).
create or replace function public.apply_entitlement(
  p_user uuid, p_original_transaction_id text, p_product_id text, p_status public.entitlement_status,
  p_expires_at timestamptz, p_grace_expires_at timestamptz, p_auto_renew boolean,
  p_environment text, p_signed_at timestamptz)
returns text
language plpgsql
security invoker
set search_path = ''
as $$
declare
  owner uuid;
  existing public.entitlements%rowtype;
begin
  if not private.is_trusted() then
    raise exception 'only the server records subscriptions' using errcode = '42501';
  end if;

  select e.user_id into owner from public.entitlements e
  where e.original_transaction_id = p_original_transaction_id;
  if owner is not null and owner <> p_user then
    raise exception 'this subscription belongs to another account' using errcode = '23505';
  end if;

  select * into existing from public.entitlements e where e.user_id = p_user for update;
  if not found then
    insert into public.entitlements (user_id, product_id, original_transaction_id, status, expires_at,
                                     grace_expires_at, auto_renew, environment, signed_at)
    values (p_user, p_product_id, p_original_transaction_id, p_status, p_expires_at,
            p_grace_expires_at, p_auto_renew, p_environment, p_signed_at);
    return 'applied';
  end if;

  if existing.original_transaction_id = p_original_transaction_id then
    if p_signed_at < existing.signed_at then
      return 'stale';
    end if;
  elsif private.entitlement_grants(existing.status, existing.expires_at, existing.grace_expires_at)
        and not private.entitlement_grants(p_status, p_expires_at, p_grace_expires_at) then
    -- A lapsed second subscription (another Apple ID) never replaces one
    -- that still works.
    return 'kept_existing';
  end if;

  update public.entitlements set
    product_id = p_product_id,
    original_transaction_id = p_original_transaction_id,
    status = p_status,
    expires_at = p_expires_at,
    grace_expires_at = p_grace_expires_at,
    auto_renew = p_auto_renew,
    environment = p_environment,
    signed_at = p_signed_at,
    updated_at = now()
  where user_id = p_user;
  return 'applied';
end;
$$;

revoke execute on function public.apply_entitlement(uuid, text, text, public.entitlement_status, timestamptz,
  timestamptz, boolean, text, timestamptz) from public, anon, authenticated;
grant execute on function public.apply_entitlement(uuid, text, text, public.entitlement_status, timestamptz,
  timestamptz, boolean, text, timestamptz) to service_role;
