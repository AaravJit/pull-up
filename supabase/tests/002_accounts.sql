-- Onboarding, username rules and account-linking guard.

begin;
create extension if not exists pgtap with schema extensions;
select plan(24);

insert into auth.users (id, email, raw_user_meta_data) values
  ('a1111111-1111-1111-1111-111111111111', 'apple-user@privaterelay.appleid.com', '{}'),
  ('a2222222-2222-2222-2222-222222222222', 'taken@example.com', '{"username":"gsxr_dan"}'),
  ('a3333333-3333-3333-3333-333333333333', 'sneaky@example.com', '{"username":"pullup_support"}');

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

-- 1–4: new accounts ------------------------------------------------------------
select matches((select username from public.profiles where id = 'a1111111-1111-1111-1111-111111111111'),
  '^driver_[0-9a-f]{10}$', 'an Apple account without a username gets a placeholder');
select is((select onboarded_at from public.profiles where id = 'a1111111-1111-1111-1111-111111111111'), null,
  'new accounts start un-onboarded');
select matches((select username from public.profiles where id = 'a3333333-3333-3333-3333-333333333333'),
  '^driver_', 'a reserved name requested at sign-up is not granted');
select is((select username from public.profiles where id = 'a2222222-2222-2222-2222-222222222222'), 'gsxr_dan',
  'a valid requested username is kept');

-- 5–10: availability -------------------------------------------------------------
select pg_temp.act_as('a1111111-1111-1111-1111-111111111111');
select is(public.username_status('GSXR_Dan'), 'taken', 'availability is case-insensitive and sees taken names');
select is(public.username_status('admin'), 'reserved', 'staff-like names are reserved');
select is(public.username_status('pullup.crew'), 'reserved', 'names starting with pullup are reserved');
select is(public.username_status('ab'), 'format', 'too short is a format problem');
select is(public.username_status('.dan'), 'format', 'leading separator is a format problem');
select is(public.username_status('rx7_kenji'), 'available', 'a free valid name is available');

-- 11–16: claiming and finishing --------------------------------------------------
select throws_ok($$ select public.complete_onboarding() $$, '22023', null, 'cannot finish onboarding with the placeholder name');
select throws_ok($$ select public.claim_username('gsxr_dan', 'Kenji') $$, '23505', null, 'cannot claim a taken name');
select throws_ok($$ select public.claim_username('support', 'Kenji') $$, '22023', null, 'cannot claim a reserved name');
select is(public.claim_username('  RX7_Kenji ', 'Kenji Mori'), 'rx7_kenji', 'claim normalises and returns the name');
select lives_ok($$ select public.complete_onboarding() $$, 'finishes onboarding after claiming a name');
select isnt((select onboarded_at from public.profiles where id = 'a1111111-1111-1111-1111-111111111111'), null,
  'onboarded_at is set');

-- 17–20: direct updates can't skip the rules --------------------------------------
select throws_ok($$ update public.profiles set username = 'official' where id = auth.uid() $$, '22023', null,
  'a direct update cannot take a reserved name');
update public.profiles set onboarded_at = null where id = auth.uid();
select isnt((select onboarded_at from public.profiles where id = 'a1111111-1111-1111-1111-111111111111'), null,
  'clients cannot clear or forge onboarded_at');
select throws_ok($$ update public.profiles set avatar_path = 'a2222222-2222-2222-2222-222222222222/face.jpg' where id = auth.uid() $$,
  '42501', null, 'avatar must live in your own folder');
select lives_ok($$ update public.profiles set avatar_path = 'a1111111-1111-1111-1111-111111111111/face.jpg' where id = auth.uid() $$,
  'avatar in your own folder is accepted');

-- 21–24: no automatic account merge by email --------------------------------------
select pg_temp.as_admin();
insert into auth.identities (user_id, provider, provider_id, identity_data)
values ('a2222222-2222-2222-2222-222222222222', 'apple', 'apple-sub-2', '{}');
select throws_ok($$
  insert into auth.identities (user_id, provider, provider_id, identity_data)
  values ('a2222222-2222-2222-2222-222222222222', 'google', 'google-sub-2', '{}') $$,
  '42501', null, 'a second provider is not linked just because the email matches');

select pg_temp.act_as('a2222222-2222-2222-2222-222222222222');
select public.begin_identity_link('google');
select pg_temp.as_admin();
select lives_ok($$
  insert into auth.identities (user_id, provider, provider_id, identity_data)
  values ('a2222222-2222-2222-2222-222222222222', 'google', 'google-sub-2', '{}') $$,
  'linking works when the signed-in user asked for it');
select is((select count(*)::int from private.identity_link_intents), 0, 'the link request is used up');

select pg_temp.act_as('a2222222-2222-2222-2222-222222222222');
select public.begin_identity_link('email');
select pg_temp.as_admin();
update private.identity_link_intents set created_at = now() - interval '11 minutes';
select throws_ok($$
  insert into auth.identities (user_id, provider, provider_id, identity_data)
  values ('a2222222-2222-2222-2222-222222222222', 'email', 'a2222222-2222-2222-2222-222222222222', '{}') $$,
  '42501', null, 'an expired link request does not authorise linking');

select * from finish();
rollback;
