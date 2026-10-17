-- Reverts 20261016000700_storage.sql (policies and grants). Buckets are left
-- in place on purpose: Supabase forbids deleting storage rows from SQL, and
-- removing buckets that may hold user uploads must be a deliberate action in
-- the dashboard or Storage API, never a side effect of a schema rollback.
grant select on all tables in schema public to anon;
drop policy if exists "Storage: upload into your own folder" on storage.objects;
drop policy if exists "Storage: replace your own files" on storage.objects;
drop policy if exists "Storage: delete your own files" on storage.objects;
drop policy if exists "Storage: avatars readable by signed-in users" on storage.objects;
drop policy if exists "Storage: vehicle media follows the vehicle" on storage.objects;
drop policy if exists "Storage: post media follows the post" on storage.objects;
