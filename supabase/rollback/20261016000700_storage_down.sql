-- Reverts 20261016000700_storage.sql. Bucket rows are removed only when
-- empty: Storage refuses to drop buckets that still hold files, which is the
-- protection we want against silently destroying user uploads.
grant select on all tables in schema public to anon;
drop policy if exists "Storage: upload into your own folder" on storage.objects;
drop policy if exists "Storage: replace your own files" on storage.objects;
drop policy if exists "Storage: delete your own files" on storage.objects;
drop policy if exists "Storage: avatars readable by signed-in users" on storage.objects;
drop policy if exists "Storage: vehicle media follows the vehicle" on storage.objects;
drop policy if exists "Storage: post media follows the post" on storage.objects;
delete from storage.buckets b
 where b.id in ('avatars', 'vehicle-media', 'post-media')
   and not exists (select 1 from storage.objects o where o.bucket_id = b.id);
