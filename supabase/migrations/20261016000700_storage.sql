-- Storage buckets. All private: files are served through short-lived signed
-- URLs, which Storage only issues when the select policy below passes. Every
-- object lives under "<owner uid>/..." so ownership is checkable by path.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('avatars', 'avatars', false, 5242880, array['image/jpeg', 'image/png', 'image/heic', 'image/webp']),
  ('vehicle-media', 'vehicle-media', false, 15728640, array['image/jpeg', 'image/png', 'image/heic', 'image/webp']),
  ('post-media', 'post-media', false, 104857600, array['image/jpeg', 'image/png', 'image/heic', 'image/webp', 'video/mp4', 'video/quicktime'])
on conflict (id) do nothing;

create policy "Storage: upload into your own folder"
  on storage.objects for insert to authenticated
  with check (
    bucket_id in ('avatars', 'vehicle-media', 'post-media')
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "Storage: replace your own files"
  on storage.objects for update to authenticated
  using (bucket_id in ('avatars', 'vehicle-media', 'post-media') and (storage.foldername(name))[1] = auth.uid()::text)
  with check ((storage.foldername(name))[1] = auth.uid()::text);

create policy "Storage: delete your own files"
  on storage.objects for delete to authenticated
  using (bucket_id in ('avatars', 'vehicle-media', 'post-media') and (storage.foldername(name))[1] = auth.uid()::text);

create policy "Storage: avatars readable by signed-in users"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'avatars'
    and not public.is_blocked_between(((storage.foldername(name))[1])::uuid, auth.uid())
  );

create policy "Storage: vehicle media follows the vehicle"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'vehicle-media'
    and (
      (storage.foldername(name))[1] = auth.uid()::text
      or exists (
        select 1 from public.vehicle_photos vp
        where vp.storage_path = name and public.can_view_vehicle(vp.vehicle_id)
      )
      or exists (
        select 1 from public.vehicles v
        where v.cover_photo_path = name and public.can_view(v.owner_id, v.visibility)
      )
    )
  );

create policy "Storage: post media follows the post"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'post-media'
    and (
      (storage.foldername(name))[1] = auth.uid()::text
      or exists (select 1 from public.post_media pm where pm.storage_path = name and public.can_view_post(pm.post_id))
    )
  );

-- Pull Up has no anonymous surface: signed-out clients get nothing from the
-- REST API at all, not even empty results.
revoke all on all tables in schema public from anon;
revoke execute on all functions in schema public from anon;
