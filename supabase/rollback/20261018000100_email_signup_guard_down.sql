-- Reverts 20261018000100_email_signup_guard.sql. Turn the hook off first
-- (Authentication > Hooks, or config.toml), or every sign-up fails because
-- the function it calls is gone. No data involved.

drop function if exists public.hook_before_user_created(jsonb);
