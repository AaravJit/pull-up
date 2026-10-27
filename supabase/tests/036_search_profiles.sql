-- Profile search RPC (20261025000350): same results and RLS as the old
-- direct select, the term never needs to be in a URL, and LIKE wildcards
-- in the term are literal.

begin;
create extension if not exists pgtap with schema extensions;
select plan(11);

insert into auth.users (id, email, raw_user_meta_data) values
  ('51000000-0000-0000-0000-000000000001', 'searcher@example.com', '{"username":"searcher"}'),
  ('51000000-0000-0000-0000-000000000002', 'ab@example.com', '{"username":"sx_alpha"}'),
  ('51000000-0000-0000-0000-000000000003', 'ab2@example.com', '{"username":"sxyalpha"}'),
  ('51000000-0000-0000-0000-000000000004', 'blocker@example.com', '{"username":"sx_blocker"}');
-- These accounts confirmed the minimum age and accepted the current terms
-- (20261025000400); 040/041 test what happens without that.
insert into public.terms_acceptances (user_id, version)
select p.id, v.version from public.profiles p, public.terms_versions v where v.is_current on conflict do nothing;
insert into private.age_checks (user_id, meets_minimum, minimum_age, method)
select id, true, 13, 'self_declared' from public.profiles on conflict do nothing;
insert into auth.users (id, email, raw_user_meta_data)
  select ('52000000-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid, 'many' || i || '@example.com',
         json_build_object('username', 'manyuser' || lpad(i::text, 2, '0'))::jsonb
  from generate_series(1, 25) as i;
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

select is(
  (select prosecdef from pg_proc where oid = 'public.search_profiles(text)'::regprocedure), false,
  'search_profiles runs as the caller, so profiles RLS applies');
select ok(
  (select proconfig @> array['search_path=""'] from pg_proc where oid = 'public.search_profiles(text)'::regprocedure),
  'search_profiles pins an empty search_path');
select ok(not has_function_privilege('anon', 'public.search_profiles(text)', 'EXECUTE'), 'anon cannot search');
select ok(has_function_privilege('authenticated', 'public.search_profiles(text)', 'EXECUTE'), 'signed-in users can search');

-- The blocker blocks the searcher before the searches run.
select pg_temp.act_as('51000000-0000-0000-0000-000000000004');
insert into public.blocks (blocker_id, blocked_id) values ('51000000-0000-0000-0000-000000000004', '51000000-0000-0000-0000-000000000001');

select pg_temp.act_as('51000000-0000-0000-0000-000000000001');
select is(
  (select array_agg(username order by username) from public.search_profiles('SX')),
  array['sx_alpha', 'sxyalpha'],
  'a case-insensitive prefix finds matching usernames and hides a person who blocked you');
select is(
  (select array_agg(username) from public.search_profiles('sx_')),
  array['sx_alpha'],
  'an underscore in the term is literal, not a one-character wildcard');
select is((select count(*)::int from public.search_profiles('%%')), 0, 'a percent sign in the term is literal');
select is((select count(*)::int from public.search_profiles('s')), 0, 'a one-character term returns nothing');
select is((select count(*)::int from public.search_profiles(null)), 0, 'a null term returns nothing');
select is((select count(*)::int from public.search_profiles('manyuser')), 20, 'at most 20 results');
select is(
  (select username from public.search_profiles('  Manyuser0') limit 1), 'manyuser01',
  'surrounding spaces are trimmed and results come in username order');

select * from finish();
rollback;
