-- Public sign-ups are Apple only (migration 20261018000100). The hook is
-- called by Supabase Auth; here it is called directly with the payloads
-- Auth sends. The API tests check the live endpoint.

begin;
create extension if not exists pgtap with schema extensions;
select plan(6);

select is(
  public.hook_before_user_created('{"user":{"app_metadata":{"provider":"email","providers":["email"]}}}') -> 'error' ->> 'http_code',
  '403', 'an email sign-up is refused');
select is(
  public.hook_before_user_created('{"user":{"app_metadata":{"provider":"phone","providers":["phone"]}}}') -> 'error' ->> 'http_code',
  '403', 'a phone sign-up is refused');
select is(
  public.hook_before_user_created('{"user":{"app_metadata":{"provider":"apple","providers":["apple"]}}}'),
  '{}'::jsonb, 'a Sign in with Apple account is allowed');
select ok(
  not has_function_privilege('anon', 'public.hook_before_user_created(jsonb)', 'execute')
  and not has_function_privilege('authenticated', 'public.hook_before_user_created(jsonb)', 'execute'),
  'clients cannot call the hook');
select ok(
  has_function_privilege('supabase_auth_admin', 'public.hook_before_user_created(jsonb)', 'execute'),
  'Supabase Auth can call the hook');
select ok(
  has_schema_privilege('supabase_auth_admin', 'public', 'usage'),
  'Supabase Auth can reach the schema the hook is in');

select * from finish();
rollback;
