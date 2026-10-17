-- Feed: posts with photo/video media, likes, comments; notifications; push
-- device tokens.
--
-- A post is visible only when the viewer may see the post AND everything it
-- attaches (vehicle, drive, meet). Inserts are rejected outright when the
-- post would be more visible than what it attaches.

create table public.posts (
  id uuid primary key default gen_random_uuid(),
  author_id uuid not null references public.profiles (id) on delete cascade,
  kind text not null default 'moment' check (kind in ('moment', 'build', 'meet', 'drive')),
  caption text not null default '' check (char_length(caption) <= 2200),
  vehicle_id uuid references public.vehicles (id) on delete cascade,
  meet_id uuid references public.meets (id) on delete set null,
  drive_id uuid references public.drives (id) on delete cascade,
  visibility public.visibility not null default 'public',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (kind <> 'build' or vehicle_id is not null),
  check (kind <> 'drive' or drive_id is not null),
  check (kind <> 'meet' or meet_id is not null)
);
create index posts_author_idx on public.posts (author_id, created_at desc);
create index posts_created_idx on public.posts (created_at desc);

create table public.post_media (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.posts (id) on delete cascade,
  storage_path text not null unique,
  media_type text not null check (media_type in ('image', 'video')),
  width integer check (width > 0),
  height integer check (height > 0),
  duration_s double precision check (duration_s > 0 and duration_s <= 180),
  position integer not null default 0
);
create index post_media_post_idx on public.post_media (post_id, position);

create table public.likes (
  post_id uuid not null references public.posts (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)
);

create table public.comments (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.posts (id) on delete cascade,
  author_id uuid not null references public.profiles (id) on delete cascade,
  body text not null check (char_length(body) between 1 and 1000),
  created_at timestamptz not null default now()
);
create index comments_post_idx on public.comments (post_id, created_at);

create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  recipient_id uuid not null references public.profiles (id) on delete cascade,
  actor_id uuid references public.profiles (id) on delete cascade,
  kind text not null check (kind in ('follow', 'follow_request', 'like', 'comment', 'meet_rsvp',
                                     'meet_updated', 'meet_cancelled', 'meet_starting_soon', 'drive_validated')),
  post_id uuid references public.posts (id) on delete cascade,
  meet_id uuid references public.meets (id) on delete cascade,
  drive_id uuid references public.drives (id) on delete cascade,
  read_at timestamptz,
  pushed_at timestamptz,
  created_at timestamptz not null default now()
);
create index notifications_recipient_idx on public.notifications (recipient_id, created_at desc);

create table public.device_tokens (
  token text primary key,
  user_id uuid not null references public.profiles (id) on delete cascade,
  platform text not null check (platform in ('ios', 'android')),
  environment text not null default 'production' check (environment in ('sandbox', 'production')),
  updated_at timestamptz not null default now()
);
create index device_tokens_user_idx on public.device_tokens (user_id);

create trigger posts_touch before update on public.posts
  for each row execute function private.touch_updated_at();

-- ---------------------------------------------------------------------------
-- Guards
-- ---------------------------------------------------------------------------

create or replace function private.guard_post()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  vis public.visibility;
begin
  if tg_op = 'UPDATE' and new.author_id <> old.author_id then
    raise exception 'author is immutable' using errcode = '42501';
  end if;
  if new.vehicle_id is not null then
    select v.visibility into vis from public.vehicles v where v.id = new.vehicle_id and v.owner_id = new.author_id;
    if vis is null then
      raise exception 'you can only post your own vehicles' using errcode = '42501';
    end if;
    if private.visibility_rank(new.visibility) > private.visibility_rank(vis) then
      raise exception 'post would be more visible than the vehicle it shows' using errcode = '42501';
    end if;
  end if;
  if new.drive_id is not null then
    select public.least_visibility(d.visibility, public.drive_history_ceiling(d.owner_id)) into vis
    from public.drives d where d.id = new.drive_id and d.owner_id = new.author_id;
    if vis is null then
      raise exception 'you can only post your own drives' using errcode = '42501';
    end if;
    if private.visibility_rank(new.visibility) > private.visibility_rank(vis) then
      raise exception 'post would be more visible than the drive it shares' using errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;

create trigger posts_guard before insert or update on public.posts
  for each row execute function private.guard_post();

create or replace function public.can_view_post(p_post uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.posts p
    where p.id = p_post
      and public.can_view(p.author_id, p.visibility)
      and (p.vehicle_id is null or public.can_view_vehicle(p.vehicle_id))
      and (p.drive_id is null or public.can_view_drive(p.drive_id))
      and (p.meet_id is null or public.can_view_meet(p.meet_id))
  );
$$;

-- Computed columns: select=*,like_count,comment_count,liked_by_me
create or replace function public.like_count(p public.posts)
returns integer language sql stable security definer set search_path = ''
as $$ select count(*)::int from public.likes l where l.post_id = p.id; $$;

create or replace function public.comment_count(p public.posts)
returns integer language sql stable security definer set search_path = ''
as $$ select count(*)::int from public.comments c where c.post_id = p.id; $$;

create or replace function public.liked_by_me(p public.posts)
returns boolean language sql stable security definer set search_path = ''
as $$ select exists (select 1 from public.likes l where l.post_id = p.id and l.user_id = auth.uid()); $$;

-- Home feed: people you follow plus yourself, newest first, keyset paged.
create or replace function public.home_feed(p_before timestamptz default null, p_limit integer default 20)
returns setof public.posts
language sql
stable
security invoker
set search_path = ''
as $$
  select p.* from public.posts p
  where (p_before is null or p.created_at < p_before)
    and (p.author_id = auth.uid() or exists (
      select 1 from public.follows f where f.follower_id = auth.uid() and f.followee_id = p.author_id and f.status = 'accepted'))
  order by p.created_at desc
  limit least(greatest(p_limit, 1), 50);
$$;

-- ---------------------------------------------------------------------------
-- Notifications fan-out
-- ---------------------------------------------------------------------------

create or replace function private.notify(recipient uuid, actor uuid, k text, post uuid default null, meet uuid default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if recipient is null or recipient = actor then
    return;
  end if;
  insert into public.notifications (recipient_id, actor_id, kind, post_id, meet_id)
  values (recipient, actor, k, post, meet);
end;
$$;

create or replace function private.on_follow()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  perform private.notify(new.followee_id, new.follower_id, case when new.status = 'pending' then 'follow_request' else 'follow' end);
  return new;
end;
$$;

create or replace function private.on_like()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  perform private.notify((select author_id from public.posts where id = new.post_id), new.user_id, 'like', new.post_id);
  return new;
end;
$$;

create or replace function private.on_comment()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  perform private.notify((select author_id from public.posts where id = new.post_id), new.author_id, 'comment', new.post_id);
  return new;
end;
$$;

create or replace function private.on_rsvp()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if new.status = 'going' then
    perform private.notify((select host_id from public.meets where id = new.meet_id), new.user_id, 'meet_rsvp', null, new.meet_id);
  end if;
  return new;
end;
$$;

create or replace function private.on_meet_change()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare
  k text;
begin
  if new.cancelled_at is not null and old.cancelled_at is null then
    k := 'meet_cancelled';
  elsif new.starts_at <> old.starts_at or new.ends_at <> old.ends_at or new.lat <> old.lat or new.lon <> old.lon or new.venue_name <> old.venue_name then
    k := 'meet_updated';
  else
    return new;
  end if;
  insert into public.notifications (recipient_id, actor_id, kind, meet_id)
  select r.user_id, new.host_id, k, new.id from public.meet_rsvps r where r.meet_id = new.id and r.user_id <> new.host_id;
  return new;
end;
$$;

create trigger follows_notify after insert on public.follows for each row execute function private.on_follow();
create trigger likes_notify after insert on public.likes for each row execute function private.on_like();
create trigger comments_notify after insert on public.comments for each row execute function private.on_comment();
create trigger rsvps_notify after insert on public.meet_rsvps for each row execute function private.on_rsvp();
create trigger meets_notify after update on public.meets for each row execute function private.on_meet_change();

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------

alter table public.posts enable row level security;
alter table public.post_media enable row level security;
alter table public.likes enable row level security;
alter table public.comments enable row level security;
alter table public.notifications enable row level security;
alter table public.device_tokens enable row level security;

create policy "Posts: visible when post and attachments are visible"
  on public.posts for select to authenticated
  using (
    public.can_view(author_id, visibility)
    and (vehicle_id is null or public.can_view_vehicle(vehicle_id))
    and (drive_id is null or public.can_view_drive(drive_id))
    and (meet_id is null or public.can_view_meet(meet_id))
  );
create policy "Posts: author creates"
  on public.posts for insert to authenticated with check (author_id = auth.uid());
create policy "Posts: author edits"
  on public.posts for update to authenticated using (author_id = auth.uid()) with check (author_id = auth.uid());
create policy "Posts: author deletes"
  on public.posts for delete to authenticated using (author_id = auth.uid());

create policy "Media: follow the post"
  on public.post_media for select to authenticated using (public.can_view_post(post_id));
create policy "Media: author attaches from own folder"
  on public.post_media for insert to authenticated
  with check (
    exists (select 1 from public.posts p where p.id = post_id and p.author_id = auth.uid())
    and split_part(storage_path, '/', 1) = auth.uid()::text
  );
create policy "Media: author removes"
  on public.post_media for delete to authenticated
  using (exists (select 1 from public.posts p where p.id = post_id and p.author_id = auth.uid()));

create policy "Likes: visible with the post"
  on public.likes for select to authenticated using (public.can_view_post(post_id));
create policy "Likes: like visible posts as yourself"
  on public.likes for insert to authenticated with check (user_id = auth.uid() and public.can_view_post(post_id));
create policy "Likes: unlike"
  on public.likes for delete to authenticated using (user_id = auth.uid());

create policy "Comments: visible with the post"
  on public.comments for select to authenticated
  using (public.can_view_post(post_id) and not public.is_blocked_between(author_id, auth.uid()));
create policy "Comments: comment on visible posts as yourself"
  on public.comments for insert to authenticated with check (author_id = auth.uid() and public.can_view_post(post_id));
create policy "Comments: author or post author deletes"
  on public.comments for delete to authenticated
  using (author_id = auth.uid() or exists (select 1 from public.posts p where p.id = post_id and p.author_id = auth.uid()));

create policy "Notifications: recipient reads"
  on public.notifications for select to authenticated using (recipient_id = auth.uid());
create policy "Notifications: recipient marks read"
  on public.notifications for update to authenticated using (recipient_id = auth.uid()) with check (recipient_id = auth.uid());
create policy "Notifications: recipient clears"
  on public.notifications for delete to authenticated using (recipient_id = auth.uid());

create policy "Device tokens: own"
  on public.device_tokens for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

grant execute on function public.can_view_post(uuid) to authenticated;
grant execute on function public.home_feed(timestamptz, integer) to authenticated;
grant execute on function public.like_count(public.posts) to authenticated;
grant execute on function public.comment_count(public.posts) to authenticated;
grant execute on function public.liked_by_me(public.posts) to authenticated;
