-- Security re-check, the findings left open by Milestone 10 and the staging
-- advisor (docs/SECURITY_REPORT.md).
--
-- Counts  like_count, comment_count, going_count and interested_count take a
--         whole row and run with owner rights. Called as an RPC with a
--         made-up row carrying a real id, they returned the counts of a post
--         or meet the caller can't see. They now count only when the caller
--         can see it. liked_by_me and my_rsvp only ever describe the caller.
-- G2      Shared routes were trimmed at both ends by a random extra 0–250 m,
--         drawn again on every rebuild, so comparing rebuilds narrowed down
--         the real start and end. The extra is now drawn once per drive and
--         kept.
-- G5      No storage quota per account. New uploads are refused once an
--         account holds 2 GB or 5,000 files across all buckets. The check
--         sees only files already stored, so one upload can overshoot by at
--         most that bucket's file size limit.
-- G7      A DM photo uploaded but never sent, or whose message was unsent,
--         stayed in dm-media forever. dm_orphaned_media lists dm-media files
--         older than a day that no message references; dm-retention deletes
--         them daily.
-- G13     Supabase's own public.rls_auto_enable() (the event trigger behind
--         "enable RLS on new tables", created with the project) is
--         executable by signed-in users through /rest/v1/rpc. Calling it does
--         nothing, but it has no business being callable. Firing the event
--         trigger doesn't need EXECUTE.

-- Counts ----------------------------------------------------------------------

create or replace function public.like_count(p public.posts)
returns integer language sql stable security definer set search_path = ''
as $$ select count(*)::int from public.likes l where l.post_id = p.id and public.can_view_post(p.id); $$;

create or replace function public.comment_count(p public.posts)
returns integer language sql stable security definer set search_path = ''
as $$ select count(*)::int from public.comments c where c.post_id = p.id and public.can_view_post(p.id); $$;

create or replace function public.going_count(m public.meets)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::int from public.meet_rsvps r
  where r.meet_id = m.id and r.status = 'going' and public.can_view_meet(m.id);
$$;

create or replace function public.interested_count(m public.meets)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::int from public.meet_rsvps r
  where r.meet_id = m.id and r.status = 'interested' and public.can_view_meet(m.id);
$$;

-- G2 --------------------------------------------------------------------------

create table private.route_trim_extra (
  drive_id uuid primary key references public.drives (id) on delete cascade,
  start_m double precision not null check (start_m >= 0 and start_m < 250),
  end_m double precision not null check (end_m >= 0 and end_m < 250)
);
revoke all on private.route_trim_extra from public, anon, authenticated;

-- Same as 20261016000300_drives.sql, except where the random extra comes from.
create or replace function private.build_shared_route(p_drive uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  d public.drives;
  pts jsonb;
  trim_m double precision;
  start_trim double precision;
  end_trim double precision;
  extra private.route_trim_extra;
  total double precision := 0;
  along double precision[] := '{}';
  lats double precision[] := '{}';
  lons double precision[] := '{}';
  rec record;
  i integer;
  hidden boolean;
  segments jsonb := '[]'::jsonb;
  current_seg jsonb := '[]'::jsonb;
  last_lat double precision;
  last_lon double precision;
begin
  select * into d from public.drives where id = p_drive;
  select points into pts from public.drive_tracks where drive_id = p_drive;
  if pts is null then
    return '[]'::jsonb;
  end if;
  select route_endpoint_trim_m into trim_m from public.privacy_settings where user_id = d.owner_id;
  trim_m := greatest(coalesce(trim_m, 400), 200);
  insert into private.route_trim_extra (drive_id, start_m, end_m)
  values (p_drive, random() * 250, random() * 250)
  on conflict (drive_id) do nothing;
  select * into extra from private.route_trim_extra where drive_id = p_drive;
  start_trim := trim_m + extra.start_m;
  end_trim := trim_m + extra.end_m;

  for rec in
    select (p ->> 1)::float8 as lat, (p ->> 2)::float8 as lon
    from jsonb_array_elements(pts) with ordinality as e(p, ord) order by ord
  loop
    if cardinality(lats) > 0 then
      total := total + public.haversine_m(lats[cardinality(lats)], lons[cardinality(lons)], rec.lat, rec.lon);
    end if;
    lats := lats || rec.lat;
    lons := lons || rec.lon;
    along := along || total;
  end loop;

  if total <= start_trim + end_trim + 200 then
    return '[]'::jsonb;
  end if;

  for i in 1 .. cardinality(lats) loop
    hidden := along[i] < start_trim or along[i] > total - end_trim
      or exists (
        select 1 from public.privacy_zones z
        where z.user_id = d.owner_id
          and public.haversine_m(z.lat, z.lon, lats[i], lons[i]) <= z.radius_m + 150
      );
    if hidden then
      if jsonb_array_length(current_seg) >= 2 then
        segments := segments || jsonb_build_array(current_seg);
      end if;
      current_seg := '[]'::jsonb;
      last_lat := null;
    elsif last_lat is null or public.haversine_m(last_lat, last_lon, lats[i], lons[i]) >= 25 then
      current_seg := current_seg || jsonb_build_array(jsonb_build_array(round(lats[i]::numeric, 4), round(lons[i]::numeric, 4)));
      last_lat := lats[i];
      last_lon := lons[i];
    end if;
  end loop;
  if jsonb_array_length(current_seg) >= 2 then
    segments := segments || jsonb_build_array(current_seg);
  end if;
  return segments;
end;
$$;

-- G5 --------------------------------------------------------------------------

-- Whether the caller may store another file. Counts every bucket: the
-- owner-folder buckets by "<uid>/...", dm-media by "<conversation>/<uid>/...".
create function private.within_storage_quota()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(sum((o.metadata ->> 'size')::bigint), 0) < 2147483648 and count(*) < 5000
  from storage.objects o
  where (o.bucket_id in ('avatars', 'vehicle-media', 'post-media') and split_part(o.name, '/', 1) = auth.uid()::text)
     or (o.bucket_id = 'dm-media' and split_part(o.name, '/', 2) = auth.uid()::text);
$$;
revoke execute on function private.within_storage_quota() from public, anon;
grant execute on function private.within_storage_quota() to authenticated;

alter policy "Storage: upload into your own folder" on storage.objects
  with check (
    bucket_id in ('avatars', 'vehicle-media', 'post-media')
    and (storage.foldername(name))[1] = auth.uid()::text
    and private.within_storage_quota()
  );

alter policy "DM media: upload into your conversations" on storage.objects
  with check (
    bucket_id = 'dm-media'
    and split_part(name, '/', 2) = auth.uid()::text
    and private.dm_path_member(name, auth.uid())
    and private.within_storage_quota()
  );

-- G7 --------------------------------------------------------------------------

create index if not exists messages_media_path_idx on public.messages (media_path) where media_path is not null;

create function public.dm_orphaned_media(p_limit integer default 1000)
returns table (name text)
language sql
stable
security definer
set search_path = ''
as $$
  select o.name from storage.objects o
  where o.bucket_id = 'dm-media'
    and o.created_at < now() - interval '1 day'
    and not exists (select 1 from public.messages m where m.media_path = o.name)
  order by o.created_at
  limit least(greatest(p_limit, 1), 1000);
$$;
revoke execute on function public.dm_orphaned_media(integer) from public, anon, authenticated;
grant execute on function public.dm_orphaned_media(integer) to service_role;

-- G13 -------------------------------------------------------------------------

do $$
begin
  if to_regprocedure('public.rls_auto_enable()') is not null then
    revoke execute on function public.rls_auto_enable() from public, anon, authenticated;
  end if;
end;
$$;
