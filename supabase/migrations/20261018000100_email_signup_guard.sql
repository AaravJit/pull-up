-- Pull Up accounts are created with Sign in with Apple (Google on Android
-- later). The email provider stays on for signing in to accounts an admin
-- made (the App Review demo account, CI's synthetic users), but nobody can
-- register one through the public sign-up endpoint: this "before user
-- created" auth hook refuses it on the server, whatever the client does.
--
-- Accounts created with the service-role admin API don't go through this
-- hook (checked by supabase/tests/api/two_accounts_test.ts).
--
-- Enabled by supabase/config.toml locally; on hosted projects, turn it on
-- under Authentication > Hooks (docs/SUPABASE_SETUP.md step 5).

create or replace function public.hook_before_user_created(event jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
begin
  if coalesce(event -> 'user' -> 'app_metadata' ->> 'provider', '') in ('email', 'phone') then
    return jsonb_build_object('error', jsonb_build_object(
      'http_code', 403,
      'message', 'New Pull Up accounts are created with Sign in with Apple.'
    ));
  end if;
  return '{}'::jsonb;
end;
$$;

revoke execute on function public.hook_before_user_created(jsonb) from public, anon, authenticated;
grant execute on function public.hook_before_user_created(jsonb) to supabase_auth_admin;
