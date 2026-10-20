-- Reverses 20261018000400_drive_privacy.sql. The exploration cells are
-- copied back to drives.explored_cells before their table is dropped.

alter policy "Drives: visible per visibility and history ceiling" on public.drives
  using (public.can_view(owner_id, public.least_visibility(visibility, public.drive_history_ceiling(owner_id))));

create or replace function public.can_view_drive(p_drive uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.drives d
    where d.id = p_drive
      and public.can_view(d.owner_id, public.least_visibility(d.visibility, public.drive_history_ceiling(d.owner_id)))
  );
$$;

create or replace function public.drive_history_ceiling(p_owner uuid)
returns public.visibility
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select drive_history_visibility from public.privacy_settings where user_id = p_owner), 'private'::public.visibility);
$$;

drop function if exists private.drive_visible(uuid, public.visibility);

create or replace function public.leaderboard(
  p_metric text,
  p_scope text default 'global',
  p_period text default 'week',
  p_vehicle_kind public.vehicle_kind default null,
  p_limit integer default 50
)
returns table (rank bigint, profile jsonb, value double precision, vehicle_title text, is_me boolean)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  viewer uuid := auth.uid();
  since timestamptz;
  my_country text;
  my_region text;
  performance boolean := p_metric in ('zero_to_sixty', 'top_speed');
begin
  if viewer is null then
    raise exception 'sign in required' using errcode = '42501';
  end if;
  if p_metric not in ('distance', 'drives', 'exploration', 'community', 'zero_to_sixty', 'top_speed') then
    raise exception 'unknown metric %', p_metric using errcode = '22023';
  end if;
  if p_scope not in ('global', 'country', 'region', 'friends') then
    raise exception 'unknown scope %', p_scope using errcode = '22023';
  end if;
  since := case p_period
    when 'week' then date_trunc('week', now())
    when 'month' then date_trunc('month', now())
    when 'all_time' then '-infinity'::timestamptz
    else null end;
  if since is null then
    raise exception 'unknown period %', p_period using errcode = '22023';
  end if;
  select country_code, region_code into my_country, my_region from public.profile_details where user_id = viewer;
  if p_scope = 'country' and my_country is null then
    raise exception 'set your country in your profile to see country rankings' using errcode = '22023';
  end if;
  if p_scope = 'region' and my_region is null then
    raise exception 'set your region in your profile to see regional rankings' using errcode = '22023';
  end if;

  return query
  with eligible as (
    select p.id, p.username, p.display_name, p.avatar_path
    from public.profiles p
    join public.privacy_settings ps on ps.user_id = p.id
    join public.profile_details pd on pd.user_id = p.id
    where ps.leaderboard_opt_in
      and (not performance or ps.performance_leaderboard_opt_in)
      and p.visibility <> 'private'
      and not public.is_blocked_between(p.id, viewer)
      and case p_scope
            when 'country' then pd.country_code = my_country
            when 'region' then pd.region_code = my_region
            when 'friends' then p.id = viewer or public.is_friend(p.id, viewer)
            else true end
  ),
  drives as (
    select d.*, v.kind as vkind, v.year, v.make, v.model
    from public.drives d
    join eligible e on e.id = d.owner_id
    left join public.vehicles v on v.id = d.vehicle_id
    where d.validation_status = 'validated'
      and d.started_at >= since
      and (p_vehicle_kind is null or v.kind = p_vehicle_kind)
      and (not performance or d.closed_course_meet_id is not null)
  ),
  scores as (
    select d.owner_id as uid, sum(d.server_distance_m) as score, null::uuid as best_drive
      from drives d where p_metric = 'distance' group by d.owner_id
    union all
    select d.owner_id, count(*)::float8, null from drives d
      where p_metric = 'drives' and d.server_distance_m >= 1000 group by d.owner_id
    union all
    select x.owner_id, count(distinct x.cell)::float8, null
      from (select d.owner_id, unnest(d.explored_cells) as cell from drives d where p_metric = 'exploration') x
      group by x.owner_id
    union all
    select e.id,
           ((select count(*) from public.meet_rsvps r join public.meets m on m.id = r.meet_id
              where r.user_id = e.id and r.status = 'going' and m.cancelled_at is null
                and m.ends_at < now() and m.ends_at >= since)
            + 2 * (select count(*) from public.meets m
              where m.host_id = e.id and m.cancelled_at is null and m.ends_at < now() and m.ends_at >= since
                and (select count(*) from public.meet_rsvps r where r.meet_id = m.id and r.status = 'going') >= 3))::float8,
           null
      from eligible e where p_metric = 'community'
    union all
    (select distinct on (d.owner_id) d.owner_id, d.zero_to_sixty_s, d.id
      from drives d
      where p_metric = 'zero_to_sixty' and d.zero_to_sixty_s is not null and d.zero_to_sixty_quality = 'consistent'
      order by d.owner_id, d.zero_to_sixty_s asc)
    union all
    (select distinct on (d.owner_id) d.owner_id, least(d.top_speed_mps, d.server_top_speed_mps), d.id
      from drives d
      where p_metric = 'top_speed' and d.top_speed_mps is not null
      order by d.owner_id, least(d.top_speed_mps, d.server_top_speed_mps) desc)
  ),
  ranked as (
    select s.uid, s.score, s.best_drive,
           rank() over (order by case when p_metric = 'zero_to_sixty' then s.score else -s.score end) as r
    from scores s
    where s.score is not null and s.score > 0
  )
  select ranked.r,
         jsonb_build_object('id', e.id, 'username', e.username, 'display_name', e.display_name, 'avatar_path', e.avatar_path),
         ranked.score,
         (select format('%s %s %s', v.year, v.make, v.model)
            from public.drives d join public.vehicles v on v.id = d.vehicle_id
           where d.id = ranked.best_drive and public.can_view(v.owner_id, v.visibility)),
         e.id = viewer
  from ranked
  join eligible e on e.id = ranked.uid
  where ranked.r <= least(greatest(p_limit, 1), 200) or e.id = viewer
  order by ranked.r, e.username;
end;
$$;

drop trigger if exists drives_stash_cells on public.drives;
drop function if exists private.stash_drive_cells();

update public.drives d set explored_cells = c.cells
  from private.drive_cells c where c.drive_id = d.id;
drop table if exists private.drive_cells;
