-- Reverses 20261025000200_post_publishing.sql: drops publish_post and
-- post_orphaned_media and lets authors insert post_media rows directly
-- again, with the policy from 20261016000500_social.sql. No data is touched;
-- posts and media made through publish_post stay as they are.

drop function if exists public.post_orphaned_media(integer);
drop function if exists public.publish_post(uuid, text, text, public.visibility, uuid, uuid, uuid, jsonb);

grant insert, update on public.post_media to authenticated;
drop policy if exists "Media: author attaches from own folder" on public.post_media;
create policy "Media: author attaches from own folder"
  on public.post_media for insert to authenticated
  with check (
    exists (select 1 from public.posts p where p.id = post_id and p.author_id = auth.uid())
    and split_part(storage_path, '/', 1) = auth.uid()::text
  );
