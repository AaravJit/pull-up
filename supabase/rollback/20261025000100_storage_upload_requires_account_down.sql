-- Reverts 20261025000100_storage_upload_requires_account.sql: the upload
-- policy as set in 20261018000800_security_open_findings.sql. No data is touched.

alter policy "Storage: upload into your own folder" on storage.objects
  with check (
    bucket_id in ('avatars', 'vehicle-media', 'post-media')
    and (storage.foldername(name))[1] = auth.uid()::text
    and private.within_storage_quota()
  );

drop function if exists private.account_exists();
