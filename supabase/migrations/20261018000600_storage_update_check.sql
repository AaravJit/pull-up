-- Security re-check, G11 (docs/SECURITY_REPORT.md).
--
-- The update policy checked only the folder of the new row, so someone could
-- move one of their own files into a bucket they can't upload to, such as
-- dm-media, skipping that bucket's checks. The new row must now stay in the
-- three owner-folder buckets.

alter policy "Storage: replace your own files" on storage.objects
  with check (
    bucket_id in ('avatars', 'vehicle-media', 'post-media')
    and (storage.foldername(name))[1] = auth.uid()::text
  );
