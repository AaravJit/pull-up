-- Reverts 20261025000310_moderation_enforcement.sql. Earlier definitions
-- come back as they were. This throws away the audit log, suspensions,
-- delivery status and media queue, un-hides removed content, and makes
-- reports cascade with accounts again; so it refuses to run while any of
-- that holds data, unless pullup.allow_destructive_rollback = on (after a
-- backup). Reports whose reporter or subject was deleted are deleted, since
-- the old columns can't be null.

do $$
begin
  if (exists (select 1 from private.moderation_audit)
      or exists (select 1 from private.account_suspensions)
      or exists (select 1 from private.moderators)
      or exists (select 1 from public.reports where reporter_id is null or subject_id is null)
      or exists (select 1 from public.posts where moderation_state is not null)
      or exists (select 1 from public.comments where moderation_state is not null)
      or exists (select 1 from public.meets where moderation_state is not null)
      or exists (select 1 from public.vehicles where moderation_state is not null)
      or exists (select 1 from public.messages where moderation_state is not null))
     and coalesce(current_setting('pullup.allow_destructive_rollback', true), '') <> 'on' then
    raise exception 'moderation records exist; export them and set pullup.allow_destructive_rollback = on to proceed';
  end if;
end $$;

-- Functions
drop function if exists public.moderation_purge();
drop function if exists public.moderation_media_removed(text, text[], text);
drop function if exists public.moderation_due_media(integer);
drop function if exists public.moderation_summary();
drop function if exists public.moderation_record_delivery(uuid[], boolean, text);
drop function if exists public.moderation_claim_deliveries(integer);
drop function if exists public.mod_check_text(text);
drop function if exists public.mod_terms();
drop function if exists public.mod_remove_term(text);
drop function if exists public.mod_add_term(text, text, text, text);
drop function if exists public.mod_reset_profile(uuid, text[], uuid, text, interval);
drop function if exists public.mod_unsuspend_user(uuid, text);
drop function if exists public.mod_suspend_user(uuid, timestamptz, text, uuid, boolean);
drop function if exists public.mod_set_content_state(text, uuid, text, uuid, text, interval);
drop function if exists public.mod_resolve_report(uuid, text, text);
drop function if exists public.mod_report(uuid);
drop function if exists public.mod_queue(text, integer);
drop function if exists public.my_moderation_status();

create or replace function public.report_user(
  p_subject uuid, p_reason text, p_details text default '', p_message uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  snap jsonb;
  conv uuid;
  report_id uuid;
begin
  if me is null or p_subject is null or p_subject = me then
    raise exception 'can''t report this' using errcode = '42501';
  end if;
  if (select count(*) from public.reports where reporter_id = me and created_at > now() - interval '1 day') >= 20 then
    raise exception 'too many reports today' using errcode = '54000';
  end if;
  if p_message is not null then
    -- Only messages you can read, sent by the person you're reporting.
    select jsonb_build_object('body', m.body, 'media_path', m.media_path, 'shared_kind', m.shared_kind,
                              'shared_id', m.shared_id, 'created_at', m.created_at), m.conversation_id
      into snap, conv
    from public.messages m
    where m.id = p_message and m.sender_id = p_subject and private.is_member(m.conversation_id, me);
    if snap is null then
      raise exception 'can''t report this' using errcode = '42501';
    end if;
  end if;
  insert into public.reports (reporter_id, subject_id, conversation_id, message_id, reason, details, snapshot)
  values (me, p_subject, conv, p_message, p_reason, left(coalesce(p_details, ''), 1000), snap)
  returning id into report_id;
  -- Moderation hook: a listener or a Database Webhook on public.reports can
  -- route this to staff. Nothing about the reporter is sent to the subject.
  perform pg_notify('pullup_reports', report_id::text);
  return report_id;
end;
$$;

create or replace function public.report_content(p_kind text, p_id uuid, p_reason text, p_details text default '')
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  subject uuid;
  snap jsonb;
  report_id uuid;
begin
  if p_kind = 'post' then
    select p.author_id,
           jsonb_build_object('caption', p.caption, 'kind', p.kind, 'visibility', p.visibility, 'created_at', p.created_at,
                              'media', (select coalesce(jsonb_agg(pm.storage_path order by pm.position), '[]'::jsonb)
                                        from public.post_media pm where pm.post_id = p.id))
      into subject, snap
    from public.posts p
    where p.id = p_id and public.can_view_post(p.id);
  elsif p_kind = 'comment' then
    select c.author_id, jsonb_build_object('body', c.body, 'post_id', c.post_id, 'created_at', c.created_at)
      into subject, snap
    from public.comments c
    where c.id = p_id and public.can_view_post(c.post_id) and not public.is_blocked_between(c.author_id, me);
  elsif p_kind = 'meet' then
    select m.host_id,
           jsonb_build_object('title', m.title, 'details', m.details, 'venue_name', m.venue_name,
                              'starts_at', m.starts_at, 'created_at', m.created_at)
      into subject, snap
    from public.meets m
    where m.id = p_id and public.can_view_meet(m.id);
  elsif p_kind = 'profile' then
    select p.id,
           jsonb_build_object('username', p.username, 'display_name', p.display_name, 'avatar_path', p.avatar_path,
                              'bio', case when public.can_view(p.id, p.visibility) then d.bio end)
      into subject, snap
    from public.profiles p
    left join public.profile_details d on d.user_id = p.id
    where p.id = p_id and not public.is_blocked_between(p.id, me);
  end if;
  if subject is null then
    raise exception 'can''t report this' using errcode = '42501';
  end if;
  report_id := public.report_user(subject, p_reason, p_details, null);
  update public.reports
     set snapshot = snap || jsonb_build_object('content_kind', p_kind, 'content_id', p_id)
   where id = report_id;
  return report_id;
end;
$$;

drop function if exists private.queue_media_purge(text, uuid, timestamptz);
drop table if exists private.moderation_media_purge;
drop function if exists private.set_moderation_state(text, uuid, text);

-- Reports
drop trigger if exists reports_queue_delivery on public.reports;
drop function if exists private.queue_report_delivery();
drop table if exists private.moderation_deliveries;
drop trigger if exists reports_touch on public.reports;
delete from public.reports where reporter_id is null or subject_id is null;
alter table public.reports drop constraint reports_subject_id_fkey;
alter table public.reports add constraint reports_subject_id_fkey
  foreign key (subject_id) references public.profiles (id) on delete cascade;
alter table public.reports drop constraint reports_reporter_id_fkey;
alter table public.reports add constraint reports_reporter_id_fkey
  foreign key (reporter_id) references public.profiles (id) on delete cascade;
alter table public.reports alter column reporter_id set not null, alter column subject_id set not null;
drop index if exists public.reports_subject_idx;
drop index if exists public.reports_content_idx;
alter table public.reports
  drop column if exists resolved_at,
  drop column if exists updated_at,
  drop column if exists priority,
  drop column if exists content_id,
  drop column if exists content_kind;

-- Storage
alter policy "Storage: avatars readable by signed-in users" on storage.objects
  using (
    bucket_id = 'avatars'
    and not public.is_blocked_between(((storage.foldername(name))[1])::uuid, auth.uid())
  );
drop index if exists public.profiles_avatar_path_idx;

-- Read paths
create or replace function public.inbox(p_state text default 'active', p_before timestamptz default null, p_limit integer default 30)
returns table (
  conversation_id uuid,
  peer_id uuid,
  peer_username text,
  peer_display_name text,
  peer_avatar_path text,
  state text,
  muted boolean,
  last_message_at timestamptz,
  last_message_preview text,
  last_message_from_me boolean,
  unread_count integer,
  peer_read_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    c.id,
    p.id, p.username, p.display_name, p.avatar_path,
    cm.state, cm.muted, c.last_message_at,
    case
      when lm.unsent_at is not null then 'Message unsent'
      when lm.media_path is not null and btrim(lm.body) = '' then 'Photo'
      when lm.shared_kind is not null and btrim(lm.body) = '' then 'Shared a ' || lm.shared_kind
      else left(lm.body, 140)
    end,
    lm.sender_id = auth.uid(),
    (select count(*)::int from public.messages m
     where m.conversation_id = c.id and m.sender_id <> auth.uid() and m.unsent_at is null
       and m.created_at > coalesce(greatest(cm.last_read_at, cm.cleared_at), '-infinity'::timestamptz)),
    public.peer_read_at(c.id)
  from public.conversation_members cm
  join public.conversations c on c.id = cm.conversation_id
  join public.profiles p on p.id = private.peer_of(c.id, auth.uid())
  left join lateral (
    select m.* from public.messages m
    where m.conversation_id = c.id and m.created_at > coalesce(cm.cleared_at, '-infinity'::timestamptz)
    order by m.created_at desc limit 1
  ) lm on true
  where cm.user_id = auth.uid()
    and cm.state = p_state
    and lm.id is not null
    and (cm.hidden_at is null or c.last_message_at > cm.hidden_at)
    and not public.is_blocked_between(p.id, auth.uid())
    and (p_before is null or c.last_message_at < p_before)
  order by c.last_message_at desc
  limit least(greatest(p_limit, 1), 50);
$$;

create or replace function public.comment_count(p public.posts)
returns integer language sql stable security definer set search_path = ''
as $$ select count(*)::int from public.comments c where c.post_id = p.id and public.can_view_post(p.id); $$;

create or replace function private.can_read_message(p_message uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.messages m
    join public.conversation_members cm on cm.conversation_id = m.conversation_id and cm.user_id = auth.uid()
    where m.id = p_message
      and m.created_at > coalesce(cm.cleared_at, '-infinity'::timestamptz)
      and not public.is_blocked_between(m.sender_id, auth.uid())
      and not public.is_blocked_between(private.peer_of(m.conversation_id, auth.uid()), auth.uid())
  );
$$;

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

create or replace function public.can_view_meet(p_meet uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.meets m where m.id = p_meet and public.can_view(m.host_id, m.visibility));
$$;

create or replace function public.can_view_vehicle(p_vehicle uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.vehicles v where v.id = p_vehicle and public.can_view(v.owner_id, v.visibility));
$$;

drop policy if exists "Posts: hidden by moderation" on public.posts;
drop policy if exists "Comments: hidden by moderation" on public.comments;
drop policy if exists "Meets: hidden by moderation" on public.meets;
drop policy if exists "Vehicles: hidden by moderation" on public.vehicles;
drop policy if exists "Messages: hidden by moderation" on public.messages;
drop function if exists private.moderation_visible(text, uuid);
drop trigger if exists posts_protect_moderation on public.posts;
drop trigger if exists comments_protect_moderation on public.comments;
drop trigger if exists meets_protect_moderation on public.meets;
drop trigger if exists vehicles_protect_moderation on public.vehicles;
drop trigger if exists messages_protect_moderation on public.messages;
drop function if exists private.protect_moderation_state();
alter table public.posts drop column if exists moderated_at, drop column if exists moderation_state;
alter table public.comments drop column if exists moderated_at, drop column if exists moderation_state;
alter table public.meets drop column if exists moderated_at, drop column if exists moderation_state;
alter table public.vehicles drop column if exists moderated_at, drop column if exists moderation_state;
alter table public.messages drop column if exists moderated_at, drop column if exists moderation_state;

-- Blocks
drop trigger if exists meet_rsvps_block on public.meet_rsvps;
drop function if exists private.guard_rsvp_block();

-- Suspension
drop policy if exists "Storage: suspended accounts can't upload" on storage.objects;
drop trigger if exists profiles_active_account on public.profiles;
drop trigger if exists profile_details_active_account on public.profile_details;
drop trigger if exists vehicles_active_account on public.vehicles;
drop trigger if exists vehicle_mods_active_account on public.vehicle_mods;
drop trigger if exists vehicle_photos_active_account on public.vehicle_photos;
drop trigger if exists posts_active_account on public.posts;
drop trigger if exists post_media_active_account on public.post_media;
drop trigger if exists likes_active_account on public.likes;
drop trigger if exists comments_active_account on public.comments;
drop trigger if exists meets_active_account on public.meets;
drop trigger if exists meet_rsvps_active_account on public.meet_rsvps;
drop trigger if exists follows_active_account on public.follows;
drop trigger if exists conversations_active_account on public.conversations;
drop trigger if exists messages_active_account on public.messages;
drop trigger if exists message_reactions_active_account on public.message_reactions;
drop function if exists private.enforce_active_account();
drop function if exists private.suspension_message(uuid);
drop function if exists private.is_suspended(uuid);
drop table if exists private.account_suspensions;

-- Moderators and audit
drop trigger if exists moderation_terms_audit on private.moderation_terms;
drop function if exists private.audit_terms();
drop trigger if exists moderators_audit on private.moderators;
drop function if exists private.audit_moderators();
drop function if exists private.audit(uuid, text, text, uuid, uuid, text, uuid, jsonb, text);
drop function if exists private.moderation_actor();
drop function if exists private.is_moderator(uuid);
drop table if exists private.moderation_audit;
drop function if exists private.audit_append_only();
drop table if exists private.moderators;
