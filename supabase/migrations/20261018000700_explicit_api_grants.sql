-- Table privileges for the API roles, stated explicitly.
--
-- Newer Supabase projects don't give anon, authenticated and service_role
-- SELECT/INSERT/UPDATE/DELETE on new tables in public by default
-- (pull-up-staging, created 2026-10-18, is one). The earlier
-- migrations relied on the old default and only revoked what clients must
-- not do, so on a new project every table answered "permission denied",
-- for the Edge Functions' service role too. The local stack still has the
-- old default, so CI never saw it.
--
-- This grants what the old default gave and then repeats the earlier
-- revokes, so both kinds of project end up the same. RLS still decides
-- which rows anyone sees. Any new table needs its own grants.

grant select, insert, update, delete on all tables in schema public to authenticated, service_role;

-- Pull Up has no anonymous surface (20261016000700_storage.sql).
revoke all on all tables in schema public from anon;

-- Repeated from 20261017000200_direct_messages.sql.
revoke update on public.messages from authenticated;
revoke insert, update, delete on public.conversations from authenticated;
revoke insert, update, delete on public.conversation_members from authenticated;
revoke insert, update, delete on public.reports from authenticated;

-- Repeated from 20261017000300_pro_entitlements.sql: Pro is granted only by
-- the Edge Functions, and App Store notifications are service role only.
revoke insert, update, delete, truncate on public.entitlements from anon, authenticated;
revoke all on public.app_store_notifications from anon, authenticated;

-- Repeated from 20261017000400_notification_preferences.sql.
revoke delete, truncate on public.notification_preferences from authenticated;
revoke insert, update on public.device_tokens from anon, authenticated;
