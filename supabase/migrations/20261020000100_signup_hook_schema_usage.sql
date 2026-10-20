-- Supabase Auth runs the before-user-created hook (20261018000100) as
-- supabase_auth_admin, which needs USAGE on schema public to reach the
-- function. Today it gets that through PUBLIC's grant on the schema; Supabase's
-- auth hooks guide asks for the grant to be explicit, so tightening PUBLIC
-- later can't silently break every sign-up. Kept out of 20261018000100
-- because staging has already applied that file.

grant usage on schema public to supabase_auth_admin;
