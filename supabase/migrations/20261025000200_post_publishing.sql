-- Posts appear complete or not at all.
--
-- The app used to insert the post first and then upload its photos and
-- videos one by one, adding a post_media row after each. A failed or
-- cancelled upload left a visible post with some or none of its media, and
-- a retry after a lost response made a second post.
--
-- Now the app uploads every file first, into post-media under
-- "<uid>/<post id>/", with a post id it generates once per draft. Then
-- publish_post checks that each file is really in storage and writes the
-- post and all of its post_media rows in one transaction, so nobody (the
-- author included) ever sees a post whose media is missing. Calling it again
-- with the same id returns the post already made instead of a second one.
--
-- post_media rows can no longer be inserted directly: media is attached
-- only by publish_post, which checks the files exist. Posts without media
-- can still be inserted directly; they are complete as soon as they exist.
--
-- Files uploaded for a draft that never publishes (upload failed, app
-- killed, draft abandoned) belong to no post. They are visible only to
-- their owner, count against the owner's storage quota (20261018000800, G5)
-- and are listed by post_orphaned_media a day after upload, along with the
-- files of deleted posts, for the post-media-cleanup function to delete.

drop policy if exists "Media: author attaches from own folder" on public.post_media;
revoke insert, update on public.post_media from authenticated;

create function public.publish_post(
  p_id uuid,
  p_kind text default 'moment',
  p_caption text default '',
  p_visibility public.visibility default 'public',
  p_vehicle_id uuid default null,
  p_meet_id uuid default null,
  p_drive_id uuid default null,
  p_media jsonb default '[]'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  existing uuid;
  item jsonb;
  item_path text;
  item_type text;
  mime text;
  folder text;
begin
  if me is null then
    raise exception 'sign in to post' using errcode = '42501';
  end if;
  if p_id is null then
    raise exception 'a post needs an id' using errcode = '22023';
  end if;

  -- The same id again (a double tap, or a retry after the response was
  -- lost) returns the post that call made. Nothing is inserted, so insert
  -- triggers (rate limits, filters) don't count it twice.
  select p.author_id into existing from public.posts p where p.id = p_id;
  if found then
    if existing = me then
      return p_id;
    end if;
    raise exception 'this post id is already used' using errcode = '42501';
  end if;

  p_media := coalesce(p_media, '[]'::jsonb);
  if jsonb_typeof(p_media) <> 'array' then
    raise exception 'media must be a list' using errcode = '22023';
  end if;
  if jsonb_array_length(p_media) > 10 then
    raise exception 'a post can have at most 10 photos and videos' using errcode = '22023';
  end if;

  folder := me::text || '/' || p_id::text || '/';
  for item in select m.value from jsonb_array_elements(p_media) as m(value) loop
    if jsonb_typeof(item) <> 'object' then
      raise exception 'each media item must be an object' using errcode = '22023';
    end if;
    item_path := item ->> 'path';
    item_type := item ->> 'type';
    if item_type is null or item_type not in ('image', 'video') then
      raise exception 'media type must be image or video' using errcode = '22023';
    end if;
    if item_path is null or left(item_path, length(folder)) <> folder
       or substr(item_path, length(folder) + 1) !~ '^[A-Za-z0-9_-]{1,64}\.[a-z0-9]{2,5}$' then
      raise exception 'media must be uploaded to this post''s own folder' using errcode = '22023';
    end if;
    -- Storage writes the object's row once the upload has finished.
    select o.metadata ->> 'mimetype' into mime
    from storage.objects o
    where o.bucket_id = 'post-media' and o.name = item_path;
    if not found then
      raise exception 'media % has not finished uploading', item_path using errcode = 'P0002';
    end if;
    if mime is not null and split_part(mime, '/', 1) <> item_type then
      raise exception 'media % is not of type %', item_path, item_type using errcode = '22023';
    end if;
  end loop;

  insert into public.posts (id, author_id, kind, caption, vehicle_id, meet_id, drive_id, visibility)
  values (p_id, me, coalesce(p_kind, 'moment'), coalesce(p_caption, ''), p_vehicle_id, p_meet_id, p_drive_id,
          coalesce(p_visibility, 'public'))
  on conflict (id) do nothing;
  if not found then
    -- A concurrent call with the same id committed first.
    select p.author_id into existing from public.posts p where p.id = p_id;
    if existing = me then
      return p_id;
    end if;
    raise exception 'this post id is already used' using errcode = '42501';
  end if;

  insert into public.post_media (post_id, storage_path, media_type, width, height, duration_s, position)
  select p_id, m.value ->> 'path', m.value ->> 'type', (m.value ->> 'width')::integer, (m.value ->> 'height')::integer,
         (m.value ->> 'duration_s')::double precision, (m.ordinality - 1)::integer
  from jsonb_array_elements(p_media) with ordinality as m(value, ordinality);

  return p_id;
end;
$$;

revoke execute on function public.publish_post(uuid, text, text, public.visibility, uuid, uuid, uuid, jsonb) from public, anon;
grant execute on function public.publish_post(uuid, text, text, public.visibility, uuid, uuid, uuid, jsonb) to authenticated;

-- post-media files no post refers to, a day after upload: uploads for
-- drafts that never published, and the media of deleted posts. Files a
-- report's snapshot refers to (20261024000100) are kept for moderators.
-- Service role only; post-media-cleanup deletes them through the Storage API.
create function public.post_orphaned_media(p_limit integer default 1000)
returns table (name text)
language sql
stable
security definer
set search_path = ''
as $$
  select o.name from storage.objects o
  where o.bucket_id = 'post-media'
    and o.created_at < now() - interval '1 day'
    and not exists (select 1 from public.post_media pm where pm.storage_path = o.name)
    and not exists (select 1 from public.reports r where r.snapshot -> 'media' ? o.name)
  order by o.created_at
  limit least(greatest(p_limit, 1), 1000);
$$;

revoke execute on function public.post_orphaned_media(integer) from public, anon, authenticated;
grant execute on function public.post_orphaned_media(integer) to service_role;
