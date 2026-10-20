-- Reverses 20261018000800_security_open_findings.sql. Restores the earlier
-- definitions as they were, including the weaknesses that migration closed.

-- G13
do $$
begin
  if to_regprocedure('public.rls_auto_enable()') is not null then
    grant execute on function public.rls_auto_enable() to authenticated;
  end if;
end;
$$;

-- G7
drop function if exists public.dm_orphaned_media(integer);
drop index if exists public.messages_media_path_idx;

-- G5
alter policy "DM media: upload into your conversations" on storage.objects
  with check (
    bucket_id = 'dm-media'
    and split_part(name, '/', 2) = auth.uid()::text
    and private.dm_path_member(name, auth.uid())
  );
alter policy "Storage: upload into your own folder" on storage.objects
  with check (
    bucket_id in ('avatars', 'vehicle-media', 'post-media')
    and (storage.foldername(name))[1] = auth.uid()::text
  );
drop function if exists private.within_storage_quota();

-- G2
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
  start_trim := trim_m + random() * 250;
  end_trim := trim_m + random() * 250;

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

drop table if exists private.route_trim_extra;

-- Counts
create or replace function public.like_count(p public.posts)
returns integer language sql stable security definer set search_path = ''
as $$ select count(*)::int from public.likes l where l.post_id = p.id; $$;

create or replace function public.comment_count(p public.posts)
returns integer language sql stable security definer set search_path = ''
as $$ select count(*)::int from public.comments c where c.post_id = p.id; $$;

create or replace function public.going_count(m public.meets)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::int from public.meet_rsvps r where r.meet_id = m.id and r.status = 'going';
$$;

create or replace function public.interested_count(m public.meets)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::int from public.meet_rsvps r where r.meet_id = m.id and r.status = 'interested';
$$;
