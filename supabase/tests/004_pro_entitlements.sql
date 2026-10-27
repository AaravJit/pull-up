-- Pull Up Pro entitlements: only the server writes them, people read only
-- their own, and one Apple subscription unlocks one account.

begin;
create extension if not exists pgtap with schema extensions;
select plan(20);

insert into auth.users (id, email, raw_user_meta_data) values
  ('b1111111-1111-1111-1111-111111111111', 'pro-alice@example.com', '{"username":"pro_alice"}'),
  ('b2222222-2222-2222-2222-222222222222', 'pro-bob@example.com', '{"username":"pro_bob"}');
-- These accounts confirmed the minimum age and accepted the current terms
-- (20261025000400); 040/041 test what happens without that.
insert into public.terms_acceptances (user_id, version)
select p.id, v.version from public.profiles p, public.terms_versions v where v.is_current on conflict do nothing;
insert into private.age_checks (user_id, meets_minimum, minimum_age, method)
select id, true, 13, 'self_declared' from public.profiles on conflict do nothing;

create or replace function pg_temp.act_as(uid uuid) returns void language plpgsql as $$
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', uid::text, true);
end $$;

create or replace function pg_temp.as_admin() returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
end $$;

-- 1–5: clients can't grant themselves Pro ------------------------------------------
select pg_temp.act_as('b1111111-1111-1111-1111-111111111111');
select is((select count(*)::int from public.my_entitlement()), 1, 'my_entitlement always returns one row');
select is((select is_pro from public.my_entitlement()), false, 'no subscription means not Pro');
select throws_ok($$
  insert into public.entitlements (user_id, product_id, original_transaction_id, status, expires_at, environment, signed_at)
  values (auth.uid(), 'app.pullup.pro.yearly', '2000000000000001', 'active', now() + interval '1 year', 'Production', now())
$$, '42501', null, 'clients cannot insert an entitlement');
select throws_ok($$
  select public.apply_entitlement(auth.uid(), '2000000000000001', 'app.pullup.pro.yearly', 'active',
    now() + interval '1 year', null, true, 'Production', now())
$$, '42501', null, 'clients cannot call apply_entitlement');
select throws_ok($$ select private.has_pro(auth.uid()) $$, '42501', null, 'clients cannot ask whether anyone is Pro');

-- 6–9: the server records Apple's state -----------------------------------------------
select pg_temp.as_admin();
select is(public.apply_entitlement('b1111111-1111-1111-1111-111111111111', '2000000000000001', 'app.pullup.pro.monthly',
  'active', now() + interval '20 days', null, true, 'Sandbox', now() - interval '1 hour'), 'applied',
  'the server records an active subscription');
select pg_temp.act_as('b1111111-1111-1111-1111-111111111111');
select is((select is_pro from public.my_entitlement()), true, 'an active, unexpired subscription is Pro');
select is((select product_id from public.my_entitlement()), 'app.pullup.pro.monthly', 'the plan is reported');
select throws_ok($$ update public.entitlements set expires_at = now() + interval '10 years' where user_id = auth.uid() $$,
  '42501', null, 'people cannot extend their own subscription');

-- 10–12: privacy and one subscription per account -----------------------------------------
select pg_temp.act_as('b2222222-2222-2222-2222-222222222222');
select is((select count(*)::int from public.entitlements), 0, 'nobody can see another person''s entitlement');
select is((select is_pro from public.my_entitlement()), false, 'another account is not Pro');
select pg_temp.as_admin();
select throws_ok($$
  select public.apply_entitlement('b2222222-2222-2222-2222-222222222222', '2000000000000001', 'app.pullup.pro.monthly',
    'active', now() + interval '20 days', null, true, 'Sandbox', now())
$$, '23505', null, 'one Apple subscription cannot unlock a second account');

-- 13–18: lifecycle --------------------------------------------------------------------
select is(public.apply_entitlement('b1111111-1111-1111-1111-111111111111', '2000000000000001', 'app.pullup.pro.monthly',
  'revoked', now() + interval '20 days', null, false, 'Sandbox', now() - interval '2 hours'), 'stale',
  'older Apple data is ignored');
select is(private.has_pro('b1111111-1111-1111-1111-111111111111'), true, 'still Pro after a stale update');

update public.entitlements set expires_at = now() - interval '1 minute' where user_id = 'b1111111-1111-1111-1111-111111111111';
select is(private.has_pro('b1111111-1111-1111-1111-111111111111'), false,
  'an active status past its expiry date is not Pro (server clock)');

select public.apply_entitlement('b1111111-1111-1111-1111-111111111111', '2000000000000001', 'app.pullup.pro.monthly',
  'grace_period', now() - interval '1 minute', now() + interval '6 days', true, 'Sandbox', now());
select is(private.has_pro('b1111111-1111-1111-1111-111111111111'), true, 'billing grace period keeps Pro');

select public.apply_entitlement('b1111111-1111-1111-1111-111111111111', '2000000000000001', 'app.pullup.pro.monthly',
  'billing_retry', now() - interval '1 minute', null, true, 'Sandbox', now() + interval '1 second');
select is(private.has_pro('b1111111-1111-1111-1111-111111111111'), false, 'billing retry after grace is not Pro');

select public.apply_entitlement('b1111111-1111-1111-1111-111111111111', '2000000000000001', 'app.pullup.pro.monthly',
  'revoked', now() + interval '20 days', null, false, 'Sandbox', now() + interval '2 seconds');
select is(private.has_pro('b1111111-1111-1111-1111-111111111111'), false, 'a refunded or revoked subscription is not Pro');

-- 19–20: a second Apple ID ------------------------------------------------------------------
select public.apply_entitlement('b2222222-2222-2222-2222-222222222222', '2000000000000002', 'app.pullup.pro.yearly',
  'active', now() + interval '1 year', null, true, 'Production', now());
select is(public.apply_entitlement('b2222222-2222-2222-2222-222222222222', '2000000000000003', 'app.pullup.pro.monthly',
  'expired', now() - interval '1 day', null, false, 'Production', now()), 'kept_existing',
  'a lapsed second subscription never replaces one that works');
delete from auth.users where id = 'b2222222-2222-2222-2222-222222222222';
select is((select count(*)::int from public.entitlements where user_id = 'b2222222-2222-2222-2222-222222222222'), 0,
  'deleting the account deletes its entitlement');

select * from finish();
rollback;
