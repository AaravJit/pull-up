-- Reverses 20261018000600_storage_update_check.sql.

alter policy "Storage: replace your own files" on storage.objects
  with check ((storage.foldername(name))[1] = auth.uid()::text);
