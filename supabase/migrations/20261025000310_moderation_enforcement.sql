-- Moderation, part 2: moderators, an append-only audit log, the report
-- queue and its delivery outbox, content removal, account suspension, and
-- block enforcement on meet RSVPs. docs/MODERATION_RUNBOOK.md is the
-- operating manual; supabase/tests/019_moderation.sql the proof.
--
-- Moderators
--   private.moderators lists them. No client and no function can add one:
--   the owner inserts a row from the SQL editor (runbook). Every change to
--   the list is written to the audit log. The moderator functions
--   (public.mod_*) are security definer and start with
--   private.moderation_actor(), which lets through a listed moderator, or the
--   server (service role / SQL editor, no signed-in user), and nobody else.
--
-- Audit log
--   private.moderation_audit records who did what and when: every moderator
--   action, automatic hiding, suspension, term change and moderator change.
--   Rows can't be updated or deleted (a trigger refuses, for every role,
--   the owner included);
--   only public.moderation_purge removes rows older than two years. It has
--   no foreign keys, so deleting an account never rewrites it; it holds
--   account ids, not content.
--
-- Reports
--   reports gains the reported content's kind and id, a priority (threats
--   and sexual content are urgent), updated/resolved times, and keeps its
--   evidence when either account is deleted (reporter_id/subject_id become
--   null instead of the row being deleted; closed reports are still purged
--   a year later by dm_purge). The unmonitored pg_notify is replaced by
--   private.moderation_deliveries, an outbox the moderation-worker edge
--   function drains to the owner's webhook, with retries and a recorded
--   status per report. Nothing is delivered until the owner configures it.
--
-- Removal
--   posts, comments, meets, vehicles and messages get moderation_state:
--   null (visible), 'pending_review' (hidden from everyone but the author;
--   set automatically once three different established accounts report the
--   same item, or by a moderator) or 'removed' (hidden from everyone). Hidden
--   rows disappear from every read path: RLS (restrictive policies, so they
--   compose with any other policy), can_view_post/vehicle/meet (likes,
--   comments, media, shared cards, storage), can_read_message (DMs, DM
--   photos), inbox previews and comment counts. Rows are kept so the
--   evidence stays; their photos and videos are queued for deletion from
--   Storage after an evidence hold (30 days by default, or at once).
--   Profiles are reset field by field instead (name, bio, avatar, username).
--
-- Suspension
--   private.account_suspensions. While suspended, an account can't write
--   (insert or update) its profile, vehicles, mods, photos, posts, media,
--   likes, comments, meets (cancelling is still allowed), RSVPs, follows,
--   conversations, messages or reactions, nor upload files, whichever API it
--   uses (SQLSTATE PUM02). It can still read, delete its own content, block,
--   report, change privacy settings and delete the account. Drives aren't
--   blocked: they are private by default and the offline queue would retry.
--
-- Reversible: supabase/rollback/20261025000310_moderation_enforcement_down.sql.

-- ---------------------------------------------------------------------------
-- Moderators and the audit log
-- ---------------------------------------------------------------------------

create table private.moderators (
  user_id uuid primary key references auth.users (id) on delete cascade,
  note text not null default '' check (char_length(note) <= 200),
  added_at timestamptz not null default now()
);
alter table private.moderators enable row level security;
revoke all on private.moderators from public, anon, authenticated, service_role;

create table private.moderation_audit (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  -- The moderator, or null for the server / the owner in the SQL editor /
  -- an automatic action (see actor_kind).
  actor_id uuid,
  actor_kind text not null check (actor_kind in ('moderator', 'server', 'automatic')),
  action text not null,
  report_id uuid,
  subject_id uuid,
  content_kind text,
  content_id uuid,
  detail jsonb not null default '{}'::jsonb,
  note text not null default ''
);
create index moderation_audit_subject_idx on private.moderation_audit (subject_id, at);
create index moderation_audit_report_idx on private.moderation_audit (report_id);
alter table private.moderation_audit enable row level security;
revoke all on private.moderation_audit from public, anon, authenticated, service_role;

create or replace function private.audit_append_only()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' and coalesce(current_setting('pullup.moderation_purge', true), '') = 'on' then
    return old;
  end if;
  raise exception 'the moderation audit log is append-only' using errcode = '42501';
end;
$$;

create trigger moderation_audit_append_only before update or delete on private.moderation_audit
  for each row execute function private.audit_append_only();
-- No API role has any privilege on the table, so only its owner could
-- empty it wholesale, and the owner can also drop triggers: that is what
-- the database's own logs and backups are for.

create or replace function private.is_moderator(p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_user is not null and exists (select 1 from private.moderators m where m.user_id = p_user);
$$;

-- The moderator calling, or null for the server. Everyone else is refused.
-- Inside a security definer function current_user is the owner, so the
-- caller is told apart by auth.uid() and the session's API role.
create or replace function private.moderation_actor()
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
begin
  if me is not null then
    if private.is_moderator(me) then
      return me;
    end if;
    raise exception 'moderators only' using errcode = '42501';
  end if;
  if coalesce(current_setting('role', true), '') in ('anon', 'authenticated') then
    raise exception 'moderators only' using errcode = '42501';
  end if;
  return null;
end;
$$;

create or replace function private.audit(
  p_actor uuid, p_kind text, p_action text, p_report uuid, p_subject uuid,
  p_content_kind text, p_content_id uuid, p_detail jsonb, p_note text
)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into private.moderation_audit (actor_id, actor_kind, action, report_id, subject_id, content_kind, content_id, detail, note)
  values (p_actor, p_kind, p_action, p_report, p_subject, p_content_kind, p_content_id,
          coalesce(p_detail, '{}'::jsonb), left(coalesce(p_note, ''), 2000));
$$;

create or replace function private.audit_moderators()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  row jsonb := case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;
begin
  perform private.audit(auth.uid(), case when auth.uid() is null then 'server' else 'moderator' end,
    case tg_op when 'INSERT' then 'moderator_added' when 'DELETE' then 'moderator_removed' else 'moderator_changed' end,
    null, (row ->> 'user_id')::uuid, null, null,
    jsonb_build_object('session_user', session_user::text), row ->> 'note');
  return null;
end;
$$;

create trigger moderators_audit after insert or update or delete on private.moderators
  for each row execute function private.audit_moderators();

-- Term list changes are audited too, however they're made.
create or replace function private.audit_terms()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  row jsonb := case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;
begin
  perform private.audit(auth.uid(), case when auth.uid() is null then 'server' else 'moderator' end,
    case tg_op when 'INSERT' then 'term_added' when 'DELETE' then 'term_removed' else 'term_changed' end,
    null, null, null, null,
    jsonb_build_object('term', row ->> 'term', 'match', row ->> 'match', 'category', row ->> 'category'), '');
  return null;
end;
$$;

create trigger moderation_terms_audit after insert or update or delete on private.moderation_terms
  for each row execute function private.audit_terms();

-- ---------------------------------------------------------------------------
-- Suspension
-- ---------------------------------------------------------------------------

create table private.account_suspensions (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  -- null: until a moderator lifts it.
  suspended_until timestamptz,
  -- Shown to the person (my_moderation_status), so write it for them.
  reason text not null check (char_length(reason) between 1 and 500),
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now()
);
alter table private.account_suspensions enable row level security;
revoke all on private.account_suspensions from public, anon, authenticated, service_role;

create or replace function private.is_suspended(p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from private.account_suspensions s
    where s.user_id = p_user and (s.suspended_until is null or s.suspended_until > now())
  );
$$;

create or replace function private.suspension_message(p_user uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select 'Your Pull Up account is suspended'
    || coalesce(' until ' || to_char(s.suspended_until at time zone 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC', '')
    || ', so you can''t post, comment, message or edit your profile. Reason: ' || s.reason
  from private.account_suspensions s where s.user_id = p_user;
$$;

-- Trigger arguments: how to find the row's owner ('owner' <column>, or
-- 'vehicle' / 'post' <column holding its id>). Only the owner's own writes
-- are refused; a moderator or the server acting on the row isn't.
create or replace function private.enforce_active_account()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  rec jsonb := to_jsonb(new);
  ref uuid := (rec ->> tg_argv[1])::uuid;
  owner uuid;
begin
  if me is null then
    return new;
  end if;
  owner := case tg_argv[0]
    when 'vehicle' then (select v.owner_id from public.vehicles v where v.id = ref)
    when 'post' then (select p.author_id from public.posts p where p.id = ref)
    else ref
  end;
  if owner is distinct from me or not private.is_suspended(me) then
    return new;
  end if;
  -- A suspended host may still cancel a meet, so attendees hear about it.
  if tg_table_name = 'meets' and tg_op = 'UPDATE' then
    if (to_jsonb(old) ->> 'cancelled_at') is null and (rec ->> 'cancelled_at') is not null then
      return new;
    end if;
  end if;
  raise exception '%', private.suspension_message(me) using errcode = 'PUM02';
end;
$$;

create trigger profiles_active_account before insert or update on public.profiles
  for each row execute function private.enforce_active_account('owner', 'id');
create trigger profile_details_active_account before insert or update on public.profile_details
  for each row execute function private.enforce_active_account('owner', 'user_id');
create trigger vehicles_active_account before insert or update on public.vehicles
  for each row execute function private.enforce_active_account('owner', 'owner_id');
create trigger vehicle_mods_active_account before insert or update on public.vehicle_mods
  for each row execute function private.enforce_active_account('vehicle', 'vehicle_id');
create trigger vehicle_photos_active_account before insert or update on public.vehicle_photos
  for each row execute function private.enforce_active_account('vehicle', 'vehicle_id');
create trigger posts_active_account before insert or update on public.posts
  for each row execute function private.enforce_active_account('owner', 'author_id');
create trigger post_media_active_account before insert or update on public.post_media
  for each row execute function private.enforce_active_account('post', 'post_id');
create trigger likes_active_account before insert or update on public.likes
  for each row execute function private.enforce_active_account('owner', 'user_id');
create trigger comments_active_account before insert or update on public.comments
  for each row execute function private.enforce_active_account('owner', 'author_id');
create trigger meets_active_account before insert or update on public.meets
  for each row execute function private.enforce_active_account('owner', 'host_id');
create trigger meet_rsvps_active_account before insert or update on public.meet_rsvps
  for each row execute function private.enforce_active_account('owner', 'user_id');
create trigger follows_active_account before insert or update on public.follows
  for each row execute function private.enforce_active_account('owner', 'follower_id');
create trigger conversations_active_account before insert or update on public.conversations
  for each row execute function private.enforce_active_account('owner', 'created_by');
create trigger messages_active_account before insert or update on public.messages
  for each row execute function private.enforce_active_account('owner', 'sender_id');
create trigger message_reactions_active_account before insert or update on public.message_reactions
  for each row execute function private.enforce_active_account('owner', 'user_id');

-- No uploads while suspended. Restrictive, so it adds to every bucket's
-- own insert policy.
create policy "Storage: suspended accounts can't upload"
  on storage.objects as restrictive for insert to authenticated
  with check (not private.is_suspended(auth.uid()));

-- What the app shows a suspended person.
create or replace function public.my_moderation_status()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'suspended', private.is_suspended(auth.uid()),
    'suspended_until', (select s.suspended_until from private.account_suspensions s
                        where s.user_id = auth.uid() and (s.suspended_until is null or s.suspended_until > now())),
    'reason', (select s.reason from private.account_suspensions s
               where s.user_id = auth.uid() and (s.suspended_until is null or s.suspended_until > now())));
$$;

-- ---------------------------------------------------------------------------
-- Blocks: RSVPs
-- ---------------------------------------------------------------------------

-- Every other write already checks blocks (follows, messages, comments and
-- likes through can_view). An RSVP made before a block could still be
-- changed afterwards, since its update policy only checks ownership.
create or replace function private.guard_rsvp_block()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (select 1 from public.meets m where m.id = new.meet_id and public.is_blocked_between(m.host_id, new.user_id)) then
    raise exception 'you can''t join this meet' using errcode = '42501';
  end if;
  return new;
end;
$$;

create trigger meet_rsvps_block before insert or update on public.meet_rsvps
  for each row execute function private.guard_rsvp_block();

-- ---------------------------------------------------------------------------
-- Moderation state on content
-- ---------------------------------------------------------------------------

alter table public.posts
  add column moderation_state text check (moderation_state in ('pending_review', 'removed')),
  add column moderated_at timestamptz;
alter table public.comments
  add column moderation_state text check (moderation_state in ('pending_review', 'removed')),
  add column moderated_at timestamptz;
alter table public.meets
  add column moderation_state text check (moderation_state in ('pending_review', 'removed')),
  add column moderated_at timestamptz;
alter table public.vehicles
  add column moderation_state text check (moderation_state in ('pending_review', 'removed')),
  add column moderated_at timestamptz;
alter table public.messages
  add column moderation_state text check (moderation_state in ('pending_review', 'removed')),
  add column moderated_at timestamptz;

-- Only the server and the moderator functions set these.
create or replace function private.protect_moderation_state()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not private.is_trusted() then
    if tg_op = 'INSERT' then
      new.moderation_state := null;
      new.moderated_at := null;
    else
      new.moderation_state := old.moderation_state;
      new.moderated_at := old.moderated_at;
    end if;
  end if;
  return new;
end;
$$;

create trigger posts_protect_moderation before insert or update on public.posts
  for each row execute function private.protect_moderation_state();
create trigger comments_protect_moderation before insert or update on public.comments
  for each row execute function private.protect_moderation_state();
create trigger meets_protect_moderation before insert or update on public.meets
  for each row execute function private.protect_moderation_state();
create trigger vehicles_protect_moderation before insert or update on public.vehicles
  for each row execute function private.protect_moderation_state();
create trigger messages_protect_moderation before insert or update on public.messages
  for each row execute function private.protect_moderation_state();

-- Visible to this viewer as far as moderation goes: not hidden, or hidden
-- pending review and the viewer wrote it.
create or replace function private.moderation_visible(p_state text, p_owner uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select p_state is null or (p_state = 'pending_review' and p_owner = auth.uid());
$$;

create policy "Posts: hidden by moderation"
  on public.posts as restrictive for select to authenticated
  using (private.moderation_visible(moderation_state, author_id));
create policy "Comments: hidden by moderation"
  on public.comments as restrictive for select to authenticated
  using (private.moderation_visible(moderation_state, author_id));
create policy "Meets: hidden by moderation"
  on public.meets as restrictive for select to authenticated
  using (private.moderation_visible(moderation_state, host_id));
create policy "Vehicles: hidden by moderation"
  on public.vehicles as restrictive for select to authenticated
  using (private.moderation_visible(moderation_state, owner_id));
create policy "Messages: hidden by moderation"
  on public.messages as restrictive for select to authenticated
  using (moderation_state is null);

-- The owner-rights helpers behind likes, comments, media, shared cards,
-- reports and storage read the tables directly, so they check it too.
create or replace function public.can_view_vehicle(p_vehicle uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.vehicles v
    where v.id = p_vehicle and public.can_view(v.owner_id, v.visibility)
      and private.moderation_visible(v.moderation_state, v.owner_id)
  );
$$;

create or replace function public.can_view_meet(p_meet uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.meets m
    where m.id = p_meet and public.can_view(m.host_id, m.visibility)
      and private.moderation_visible(m.moderation_state, m.host_id)
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
      and private.moderation_visible(p.moderation_state, p.author_id)
      and (p.vehicle_id is null or public.can_view_vehicle(p.vehicle_id))
      and (p.drive_id is null or public.can_view_drive(p.drive_id))
      and (p.meet_id is null or public.can_view_meet(p.meet_id))
  );
$$;

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
      and m.moderation_state is null
      and m.created_at > coalesce(cm.cleared_at, '-infinity'::timestamptz)
      and not public.is_blocked_between(m.sender_id, auth.uid())
      and not public.is_blocked_between(private.peer_of(m.conversation_id, auth.uid()), auth.uid())
  );
$$;

create or replace function public.comment_count(p public.posts)
returns integer language sql stable security definer set search_path = ''
as $$
  select count(*)::int from public.comments c
  where c.post_id = p.id and c.moderation_state is null and public.can_view_post(p.id);
$$;

-- As in 20261017000200, with removed messages left out of the preview and
-- the unread count.
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
      when lm.moderation_state is not null then 'Message removed'
      when lm.unsent_at is not null then 'Message unsent'
      when lm.media_path is not null and btrim(lm.body) = '' then 'Photo'
      when lm.shared_kind is not null and btrim(lm.body) = '' then 'Shared a ' || lm.shared_kind
      else left(lm.body, 140)
    end,
    lm.sender_id = auth.uid(),
    (select count(*)::int from public.messages m
     where m.conversation_id = c.id and m.sender_id <> auth.uid() and m.unsent_at is null and m.moderation_state is null
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

-- An avatar file is readable by others only while it is someone's current
-- avatar, so a moderator resetting one (or the person changing it) takes
-- the old file out of reach at once, before it is deleted from Storage.
create index profiles_avatar_path_idx on public.profiles (avatar_path) where avatar_path is not null;
alter policy "Storage: avatars readable by signed-in users" on storage.objects
  using (
    bucket_id = 'avatars'
    and not public.is_blocked_between(((storage.foldername(name))[1])::uuid, auth.uid())
    and ((storage.foldername(name))[1] = auth.uid()::text
         or exists (select 1 from public.profiles p where p.avatar_path = name))
  );

-- ---------------------------------------------------------------------------
-- Reports: queue columns, evidence retention, delivery outbox
-- ---------------------------------------------------------------------------

alter table public.reports
  add column content_kind text check (content_kind in ('post', 'comment', 'meet', 'profile', 'vehicle', 'message')),
  add column content_id uuid,
  add column priority text not null default 'normal' check (priority in ('normal', 'urgent')),
  add column updated_at timestamptz not null default now(),
  add column resolved_at timestamptz;

update public.reports
   set content_kind = snapshot ->> 'content_kind', content_id = (snapshot ->> 'content_id')::uuid
 where snapshot ? 'content_kind' and content_kind is null;
update public.reports
   set content_kind = 'message', content_id = message_id
 where message_id is not null and content_kind is null;

create index reports_content_idx on public.reports (content_kind, content_id);
create index reports_subject_idx on public.reports (subject_id, created_at);

-- Evidence outlives either account: the ids become null, the snapshot stays.
alter table public.reports alter column reporter_id drop not null, alter column subject_id drop not null;
alter table public.reports drop constraint reports_reporter_id_fkey;
alter table public.reports add constraint reports_reporter_id_fkey
  foreign key (reporter_id) references public.profiles (id) on delete set null;
alter table public.reports drop constraint reports_subject_id_fkey;
alter table public.reports add constraint reports_subject_id_fkey
  foreign key (subject_id) references public.profiles (id) on delete set null;

create trigger reports_touch before update on public.reports
  for each row execute function private.touch_updated_at();

-- One row per report: has it reached the owner's endpoint yet?
create table private.moderation_deliveries (
  report_id uuid primary key references public.reports (id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'delivered', 'failed')),
  attempts integer not null default 0,
  next_attempt_at timestamptz not null default now(),
  last_attempt_at timestamptz,
  delivered_at timestamptz,
  last_error text,
  created_at timestamptz not null default now()
);
create index moderation_deliveries_due_idx on private.moderation_deliveries (next_attempt_at) where status = 'pending';
alter table private.moderation_deliveries enable row level security;
revoke all on private.moderation_deliveries from public, anon, authenticated, service_role;

create or replace function private.queue_report_delivery()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into private.moderation_deliveries (report_id) values (new.id) on conflict do nothing;
  return new;
end;
$$;

create trigger reports_queue_delivery after insert on public.reports
  for each row execute function private.queue_report_delivery();

insert into private.moderation_deliveries (report_id)
select r.id from public.reports r where r.status in ('open', 'reviewing')
on conflict do nothing;

-- Same rules as before (only what you can see, a daily cap), plus a
-- per-minute and per-hour cap, the content columns and a priority. The
-- pg_notify that nothing listened to is gone; the outbox above replaces it.
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
  if not public.take_function_slot(me, 'write:reports', 5, 15) then
    raise exception 'too many reports in a short time; try again later' using errcode = '54000';
  end if;
  if p_message is not null then
    select jsonb_build_object('body', m.body, 'media_path', m.media_path, 'shared_kind', m.shared_kind,
                              'shared_id', m.shared_id, 'created_at', m.created_at), m.conversation_id
      into snap, conv
    from public.messages m
    where m.id = p_message and m.sender_id = p_subject and private.is_member(m.conversation_id, me);
    if snap is null then
      raise exception 'can''t report this' using errcode = '42501';
    end if;
  end if;
  insert into public.reports (reporter_id, subject_id, conversation_id, message_id, reason, details, snapshot,
                              content_kind, content_id, priority)
  values (me, p_subject, conv, p_message, p_reason, left(coalesce(p_details, ''), 1000), snap,
          case when p_message is not null then 'message' end, p_message,
          case when p_reason in ('violence', 'sexual') then 'urgent' else 'normal' end)
  returning id into report_id;
  return report_id;
end;
$$;

-- Hides an item pending review. Used by report_content (three independent
-- reporters) and the moderator functions.
create or replace function private.set_moderation_state(p_kind text, p_id uuid, p_state text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  owner uuid;
  stamp timestamptz := case when p_state is null then null else now() end;
begin
  case p_kind
    when 'post' then
      update public.posts set moderation_state = p_state, moderated_at = stamp where id = p_id returning author_id into owner;
    when 'comment' then
      update public.comments set moderation_state = p_state, moderated_at = stamp where id = p_id returning author_id into owner;
    when 'meet' then
      update public.meets set moderation_state = p_state, moderated_at = stamp where id = p_id returning host_id into owner;
    when 'vehicle' then
      update public.vehicles set moderation_state = p_state, moderated_at = stamp where id = p_id returning owner_id into owner;
    when 'message' then
      update public.messages set moderation_state = p_state, moderated_at = stamp where id = p_id returning sender_id into owner;
    else
      raise exception 'unknown content kind %', p_kind using errcode = '22023';
  end case;
  if owner is null then
    raise exception 'no such %', p_kind using errcode = '22023';
  end if;
  return owner;
end;
$$;

-- Reports from the feed, meets, profiles and (new) vehicles. After the
-- third report of the same item by different accounts older than a day, it
-- is hidden pending review and its reports become urgent.
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
  reporters integer;
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
    where c.id = p_id and c.moderation_state is null and public.can_view_post(c.post_id)
      and not public.is_blocked_between(c.author_id, me);
  elsif p_kind = 'meet' then
    select m.host_id,
           jsonb_build_object('title', m.title, 'details', m.details, 'venue_name', m.venue_name, 'address', m.address,
                              'starts_at', m.starts_at, 'created_at', m.created_at)
      into subject, snap
    from public.meets m
    where m.id = p_id and public.can_view_meet(m.id);
  elsif p_kind = 'vehicle' then
    select v.owner_id,
           jsonb_build_object('make', v.make, 'model', v.model, 'year', v.year, 'trim', v.trim, 'nickname', v.nickname,
                              'summary', v.summary, 'cover_photo_path', v.cover_photo_path,
                              'photos', (select coalesce(jsonb_agg(vp.storage_path order by vp.position), '[]'::jsonb)
                                         from public.vehicle_photos vp where vp.vehicle_id = v.id),
                              'mods', (select coalesce(jsonb_agg(jsonb_build_object('title', vm.title, 'brand', vm.brand, 'notes', vm.notes)), '[]'::jsonb)
                                       from public.vehicle_mods vm where vm.vehicle_id = v.id))
      into subject, snap
    from public.vehicles v
    where v.id = p_id and public.can_view_vehicle(v.id);
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
     set snapshot = snap || jsonb_build_object('content_kind', p_kind, 'content_id', p_id),
         content_kind = p_kind, content_id = p_id
   where id = report_id;

  if p_kind in ('post', 'comment', 'meet', 'vehicle') then
    select count(distinct r.reporter_id) into reporters
    from public.reports r
    join public.profiles rp on rp.id = r.reporter_id
    where r.content_kind = p_kind and r.content_id = p_id and r.status in ('open', 'reviewing')
      and rp.created_at < now() - interval '1 day';
    if reporters >= 3 then
      if exists (
        select 1 from public.posts where p_kind = 'post' and id = p_id and moderation_state is null
        union all select 1 from public.comments where p_kind = 'comment' and id = p_id and moderation_state is null
        union all select 1 from public.meets where p_kind = 'meet' and id = p_id and moderation_state is null
        union all select 1 from public.vehicles where p_kind = 'vehicle' and id = p_id and moderation_state is null
      ) then
        perform private.set_moderation_state(p_kind, p_id, 'pending_review');
        perform private.audit(null, 'automatic', 'auto_hide', report_id, subject, p_kind, p_id,
                              jsonb_build_object('reporters', reporters), 'hidden pending review after reports from different accounts');
      end if;
      update public.reports set priority = 'urgent'
      where content_kind = p_kind and content_id = p_id and status in ('open', 'reviewing') and priority <> 'urgent';
    end if;
  end if;
  return report_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Media of removed content: deleted from Storage after an evidence hold
-- ---------------------------------------------------------------------------

create table private.moderation_media_purge (
  bucket text not null,
  path text not null,
  content_kind text not null,
  content_id uuid not null,
  remove_after timestamptz not null,
  removed_at timestamptz,
  last_error text,
  queued_at timestamptz not null default now(),
  primary key (bucket, path)
);
create index moderation_media_purge_due_idx on private.moderation_media_purge (remove_after) where removed_at is null;
alter table private.moderation_media_purge enable row level security;
revoke all on private.moderation_media_purge from public, anon, authenticated, service_role;

create or replace function private.queue_media_purge(p_kind text, p_id uuid, p_after timestamptz)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  n integer;
begin
  insert into private.moderation_media_purge (bucket, path, content_kind, content_id, remove_after)
  select x.bucket, x.path, p_kind, p_id, p_after
  from (
    select 'post-media' as bucket, pm.storage_path as path from public.post_media pm where p_kind = 'post' and pm.post_id = p_id
    union all
    select 'vehicle-media', vp.storage_path from public.vehicle_photos vp where p_kind = 'vehicle' and vp.vehicle_id = p_id
    union all
    select 'vehicle-media', v.cover_photo_path from public.vehicles v where p_kind = 'vehicle' and v.id = p_id and v.cover_photo_path is not null
    union all
    select 'dm-media', m.media_path from public.messages m where p_kind = 'message' and m.id = p_id and m.media_path is not null
    union all
    select 'avatars', pr.avatar_path from public.profiles pr where p_kind = 'avatar' and pr.id = p_id and pr.avatar_path is not null
  ) x
  where x.path is not null
  on conflict (bucket, path) do update set remove_after = least(private.moderation_media_purge.remove_after, excluded.remove_after);
  get diagnostics n = row_count;
  return n;
end;
$$;

-- ---------------------------------------------------------------------------
-- Moderator functions
-- ---------------------------------------------------------------------------

-- The queue, most urgent first, then oldest first. p_status 'open' means
-- open or reviewing; 'all' everything.
create or replace function public.mod_queue(p_status text default 'open', p_limit integer default 50)
returns table (
  report_id uuid,
  created_at timestamptz,
  status text,
  priority text,
  reason text,
  content_kind text,
  content_id uuid,
  details text,
  subject_id uuid,
  subject_username text,
  reporter_id uuid,
  reports_on_content integer,
  subject_reports_actioned integer,
  subject_suspended boolean,
  delivery_status text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.moderation_actor();
  return query
  select r.id, r.created_at, r.status, r.priority, r.reason, r.content_kind, r.content_id, r.details,
         r.subject_id, p.username, r.reporter_id,
         (select count(*)::int from public.reports o where r.content_id is not null and o.content_kind = r.content_kind and o.content_id = r.content_id),
         (select count(*)::int from public.reports o where o.subject_id = r.subject_id and o.status = 'actioned'),
         private.is_suspended(r.subject_id),
         d.status
  from public.reports r
  left join public.profiles p on p.id = r.subject_id
  left join private.moderation_deliveries d on d.report_id = r.id
  where case p_status
          when 'open' then r.status in ('open', 'reviewing')
          when 'all' then true
          else r.status = p_status
        end
  order by (r.priority = 'urgent') desc, r.created_at
  limit least(greatest(coalesce(p_limit, 50), 1), 200);
end;
$$;

-- One report with its evidence, the content as it is now (hidden or not),
-- and the history of actions on the report and its subject.
create or replace function public.mod_report(p_report uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  r public.reports;
  live jsonb;
begin
  perform private.moderation_actor();
  select * into r from public.reports where id = p_report;
  if r.id is null then
    raise exception 'no such report' using errcode = '22023';
  end if;
  live := case r.content_kind
    when 'post' then (select to_jsonb(x) from public.posts x where x.id = r.content_id)
    when 'comment' then (select to_jsonb(x) from public.comments x where x.id = r.content_id)
    when 'meet' then (select to_jsonb(x) from public.meets x where x.id = r.content_id)
    when 'vehicle' then (select to_jsonb(x) from public.vehicles x where x.id = r.content_id)
    when 'message' then (select to_jsonb(x) from public.messages x where x.id = r.content_id)
    when 'profile' then (select to_jsonb(x) || jsonb_build_object('bio', d.bio)
                         from public.profiles x left join public.profile_details d on d.user_id = x.id where x.id = r.content_id)
  end;
  return jsonb_build_object(
    'report', to_jsonb(r),
    'content_now', live,
    'subject_suspended', private.is_suspended(r.subject_id),
    'delivery', (select to_jsonb(d) from private.moderation_deliveries d where d.report_id = r.id),
    'history', (select coalesce(jsonb_agg(to_jsonb(a) order by a.at), '[]'::jsonb)
                from private.moderation_audit a
                where a.report_id = r.id or (r.subject_id is not null and a.subject_id = r.subject_id)));
end;
$$;

create or replace function public.mod_resolve_report(p_report uuid, p_status text, p_note text default '')
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := private.moderation_actor();
  r public.reports;
begin
  if p_status not in ('reviewing', 'actioned', 'dismissed') then
    raise exception 'status must be reviewing, actioned or dismissed' using errcode = '22023';
  end if;
  update public.reports
     set status = p_status, resolved_at = case when p_status = 'reviewing' then null else now() end
   where id = p_report
  returning * into r;
  if r.id is null then
    raise exception 'no such report' using errcode = '22023';
  end if;
  perform private.audit(actor, case when actor is null then 'server' else 'moderator' end, 'report_' || p_status,
                        r.id, r.subject_id, r.content_kind, r.content_id, '{}'::jsonb, p_note);
end;
$$;

-- p_state: 'removed', 'pending_review' or 'visible' (restore). Removing
-- marks the open reports about the item actioned and queues its photos and
-- videos for deletion from Storage after p_media_hold (the evidence hold;
-- '0 seconds' deletes them on the next worker run). Restoring cancels a
-- deletion that hasn't happened yet.
create or replace function public.mod_set_content_state(
  p_kind text, p_id uuid, p_state text, p_report uuid default null, p_note text default '',
  p_media_hold interval default interval '30 days'
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := private.moderation_actor();
  owner uuid;
  media integer := 0;
begin
  if p_state not in ('removed', 'pending_review', 'visible') then
    raise exception 'state must be removed, pending_review or visible' using errcode = '22023';
  end if;
  owner := private.set_moderation_state(p_kind, p_id, nullif(p_state, 'visible'));
  if p_state = 'removed' then
    media := private.queue_media_purge(p_kind, p_id, now() + coalesce(p_media_hold, interval '30 days'));
    update public.reports set status = 'actioned', resolved_at = now()
    where content_kind = p_kind and content_id = p_id and status in ('open', 'reviewing');
  elsif p_state = 'visible' then
    delete from private.moderation_media_purge
    where content_kind = p_kind and content_id = p_id and removed_at is null;
  end if;
  perform private.audit(actor, case when actor is null then 'server' else 'moderator' end,
                        case p_state when 'removed' then 'content_removed' when 'visible' then 'content_restored' else 'content_hidden' end,
                        p_report, owner, p_kind, p_id, jsonb_build_object('media_queued', media, 'media_hold', p_media_hold::text), p_note);
end;
$$;

-- p_until null: until lifted. p_reason is shown to the person.
-- p_remove_content also removes everything they posted (spam accounts).
create or replace function public.mod_suspend_user(
  p_user uuid, p_until timestamptz, p_reason text, p_report uuid default null, p_remove_content boolean default false
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := private.moderation_actor();
  item record;
  removed integer := 0;
begin
  if not exists (select 1 from public.profiles where id = p_user) then
    raise exception 'no such account' using errcode = '22023';
  end if;
  if p_until is not null and p_until <= now() then
    raise exception 'p_until must be in the future (null: until lifted)' using errcode = '22023';
  end if;
  insert into private.account_suspensions (user_id, suspended_until, reason, created_by)
  values (p_user, p_until, btrim(p_reason), actor)
  on conflict (user_id) do update
    set suspended_until = excluded.suspended_until, reason = excluded.reason,
        created_by = excluded.created_by, created_at = now();
  if p_remove_content then
    for item in
      select 'post' as kind, id from public.posts where author_id = p_user and moderation_state is distinct from 'removed'
      union all select 'comment', id from public.comments where author_id = p_user and moderation_state is distinct from 'removed'
      union all select 'meet', id from public.meets where host_id = p_user and moderation_state is distinct from 'removed'
      union all select 'vehicle', id from public.vehicles where owner_id = p_user and moderation_state is distinct from 'removed'
    loop
      perform private.set_moderation_state(item.kind, item.id, 'removed');
      perform private.queue_media_purge(item.kind, item.id, now() + interval '30 days');
      removed := removed + 1;
    end loop;
  end if;
  perform private.audit(actor, case when actor is null then 'server' else 'moderator' end, 'account_suspended',
                        p_report, p_user, null, null,
                        jsonb_build_object('until', p_until, 'reason', p_reason, 'content_removed', removed), '');
end;
$$;

create or replace function public.mod_unsuspend_user(p_user uuid, p_note text default '')
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := private.moderation_actor();
begin
  update private.account_suspensions set suspended_until = now() where user_id = p_user
    and (suspended_until is null or suspended_until > now());
  if not found then
    raise exception 'that account isn''t suspended' using errcode = '22023';
  end if;
  perform private.audit(actor, case when actor is null then 'server' else 'moderator' end, 'account_unsuspended',
                        null, p_user, null, null, '{}'::jsonb, p_note);
end;
$$;

-- Clears profile fields: any of 'display_name', 'bio', 'avatar' (the file
-- is queued for deletion after p_media_hold), 'username' (back to the
-- placeholder, which the person can change again).
create or replace function public.mod_reset_profile(
  p_user uuid, p_fields text[], p_report uuid default null, p_note text default '',
  p_media_hold interval default interval '30 days'
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := private.moderation_actor();
  media integer := 0;
begin
  if p_fields is null or cardinality(p_fields) = 0
     or not p_fields <@ array['display_name', 'bio', 'avatar', 'username'] then
    raise exception 'fields must be among display_name, bio, avatar, username' using errcode = '22023';
  end if;
  if not exists (select 1 from public.profiles where id = p_user) then
    raise exception 'no such account' using errcode = '22023';
  end if;
  if 'avatar' = any(p_fields) then
    media := private.queue_media_purge('avatar', p_user, now() + coalesce(p_media_hold, interval '30 days'));
  end if;
  update public.profiles
     set display_name = case when 'display_name' = any(p_fields) then '' else display_name end,
         avatar_path = case when 'avatar' = any(p_fields) then null else avatar_path end,
         username = case when 'username' = any(p_fields) then 'driver_' || substr(replace(id::text, '-', ''), 1, 10) else username end
   where id = p_user;
  if 'bio' = any(p_fields) then
    update public.profile_details set bio = '' where user_id = p_user;
  end if;
  if p_report is not null then
    update public.reports set status = 'actioned', resolved_at = now()
    where id = p_report and status in ('open', 'reviewing');
  end if;
  perform private.audit(actor, case when actor is null then 'server' else 'moderator' end, 'profile_reset',
                        p_report, p_user, 'profile', p_user, jsonb_build_object('fields', p_fields, 'media_queued', media), p_note);
end;
$$;

-- The term list.
create or replace function public.mod_add_term(
  p_term text, p_match text default 'word', p_category text default 'other', p_note text default ''
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := private.moderation_actor();
  folded text := private.moderation_fold(p_term);
begin
  if folded = '' then
    raise exception 'the term has no letters' using errcode = '22023';
  end if;
  insert into private.moderation_terms (term, match, category, note, added_by)
  values (folded, coalesce(p_match, 'word'), coalesce(p_category, 'other'), coalesce(p_note, ''), actor)
  on conflict (term) do update set match = excluded.match, category = excluded.category, note = excluded.note;
  return folded;
end;
$$;

create or replace function public.mod_remove_term(p_term text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.moderation_actor();
  delete from private.moderation_terms where term = private.moderation_fold(p_term);
  return found;
end;
$$;

create or replace function public.mod_terms()
returns table (term text, match text, category text, note text, created_at timestamptz)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.moderation_actor();
  return query select t.term, t.match, t.category, t.note, t.created_at from private.moderation_terms t order by t.category, t.term;
end;
$$;

-- Which term, if any, a text would be blocked for. For testing the list.
create or replace function public.mod_check_text(p_text text)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.moderation_actor();
  return private.moderation_match(p_text);
end;
$$;

-- ---------------------------------------------------------------------------
-- Server functions for the moderation-worker edge function (service role)
-- ---------------------------------------------------------------------------

-- Leases up to p_limit due deliveries for ten minutes and returns what the
-- alert may say: ids, reason, kind, priority and times. Never the reported
-- content or names, so a third-party chat webhook learns nothing private.
create or replace function public.moderation_claim_deliveries(p_limit integer default 20)
returns table (report_id uuid, reason text, priority text, content_kind text, created_at timestamptz, attempts integer)
language plpgsql
security definer
set search_path = ''
as $$
begin
  return query
  with due as (
    select d.report_id from private.moderation_deliveries d
    where d.status = 'pending' and d.next_attempt_at <= now()
    order by d.next_attempt_at
    limit least(greatest(coalesce(p_limit, 20), 1), 100)
    for update skip locked
  ), leased as (
    update private.moderation_deliveries d
       set next_attempt_at = now() + interval '10 minutes', last_attempt_at = now()
      from due where d.report_id = due.report_id
    returning d.report_id, d.attempts
  )
  select r.id, r.reason, r.priority, r.content_kind, r.created_at, l.attempts
  from leased l join public.reports r on r.id = l.report_id
  order by (r.priority = 'urgent') desc, r.created_at;
end;
$$;

-- Records the outcome. Failures back off exponentially (2, 4, 8 ... minutes,
-- at most 6 hours) and give up after 12 attempts (status 'failed', still
-- listed by moderation_summary and in the queue).
create or replace function public.moderation_record_delivery(p_reports uuid[], p_ok boolean, p_error text default null)
returns void
language sql
security definer
set search_path = ''
as $$
  update private.moderation_deliveries d
     set status = case when p_ok then 'delivered' when d.attempts + 1 >= 12 then 'failed' else 'pending' end,
         attempts = d.attempts + 1,
         delivered_at = case when p_ok then now() end,
         last_error = case when p_ok then null else left(coalesce(p_error, 'unknown error'), 500) end,
         next_attempt_at = case when p_ok then d.next_attempt_at
                                else now() + least(interval '1 minute' * power(2, d.attempts + 1), interval '6 hours') end
   where d.report_id = any(p_reports) and d.status = 'pending';
$$;

-- For the worker's digest and for the owner: the state of the queue.
create or replace function public.moderation_summary()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.moderation_actor();
  return jsonb_build_object(
    'open', (select count(*) from public.reports where status in ('open', 'reviewing')),
    'urgent_open', (select count(*) from public.reports where status in ('open', 'reviewing') and priority = 'urgent'),
    'oldest_open_at', (select min(created_at) from public.reports where status in ('open', 'reviewing')),
    'open_over_24h', (select count(*) from public.reports where status in ('open', 'reviewing') and created_at < now() - interval '24 hours'),
    'deliveries_pending', (select count(*) from private.moderation_deliveries where status = 'pending'),
    'deliveries_failed', (select count(*) from private.moderation_deliveries where status = 'failed'),
    'media_due', (select count(*) from private.moderation_media_purge where removed_at is null and remove_after <= now()),
    'terms', (select count(*) from private.moderation_terms),
    'moderators', (select count(*) from private.moderators));
end;
$$;

create or replace function public.moderation_due_media(p_limit integer default 100)
returns table (bucket text, path text)
language sql
stable
security definer
set search_path = ''
as $$
  select m.bucket, m.path from private.moderation_media_purge m
  where m.removed_at is null and m.remove_after <= now()
  order by m.remove_after
  limit least(greatest(coalesce(p_limit, 100), 1), 1000);
$$;

create or replace function public.moderation_media_removed(p_bucket text, p_paths text[], p_error text default null)
returns void
language sql
security definer
set search_path = ''
as $$
  update private.moderation_media_purge
     set removed_at = case when p_error is null then now() end,
         last_error = p_error
   where bucket = p_bucket and path = any(p_paths) and removed_at is null;
$$;

-- Retention for moderation records (the worker calls it each run):
-- audit rows after two years, delivery rows of closed reports after 90
-- days, lifted suspensions after two years, purged-media rows after 90 days.
-- Reports themselves are purged by dm_purge (closed ones after a year).
create or replace function public.moderation_purge()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  audit_rows integer;
  delivery_rows integer;
begin
  perform set_config('pullup.moderation_purge', 'on', true);
  delete from private.moderation_audit where at < now() - interval '2 years';
  get diagnostics audit_rows = row_count;
  perform set_config('pullup.moderation_purge', '', true);
  delete from private.moderation_deliveries d
  using public.reports r
  where r.id = d.report_id and r.status in ('actioned', 'dismissed') and d.created_at < now() - interval '90 days';
  get diagnostics delivery_rows = row_count;
  delete from private.account_suspensions where suspended_until < now() - interval '2 years';
  delete from private.moderation_media_purge where removed_at < now() - interval '90 days';
  return jsonb_build_object('audit', audit_rows, 'deliveries', delivery_rows);
end;
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------

revoke execute on function private.is_moderator(uuid) from public, anon, authenticated;
revoke execute on function private.moderation_actor() from public, anon, authenticated;
revoke execute on function private.audit(uuid, text, text, uuid, uuid, text, uuid, jsonb, text) from public, anon, authenticated;
revoke execute on function private.set_moderation_state(text, uuid, text) from public, anon, authenticated;
revoke execute on function private.queue_media_purge(text, uuid, timestamptz) from public, anon, authenticated;
revoke execute on function private.suspension_message(uuid) from public, anon, authenticated;
-- private.is_suspended stays executable by signed-in users: the storage
-- policy above runs as them. It answers yes/no for an account id only.
revoke execute on function private.is_suspended(uuid) from public, anon;
grant execute on function private.is_suspended(uuid) to authenticated, service_role;
grant execute on function private.moderation_visible(text, uuid) to authenticated, service_role;
revoke execute on function private.moderation_visible(text, uuid) from public, anon;

revoke execute on function public.my_moderation_status() from public, anon;
grant execute on function public.my_moderation_status() to authenticated;

-- Moderator functions: callable by signed-in users so a moderator's own
-- account can use them; each refuses anyone not in private.moderators.
revoke execute on function public.mod_queue(text, integer) from public, anon;
revoke execute on function public.mod_report(uuid) from public, anon;
revoke execute on function public.mod_resolve_report(uuid, text, text) from public, anon;
revoke execute on function public.mod_set_content_state(text, uuid, text, uuid, text, interval) from public, anon;
revoke execute on function public.mod_suspend_user(uuid, timestamptz, text, uuid, boolean) from public, anon;
revoke execute on function public.mod_unsuspend_user(uuid, text) from public, anon;
revoke execute on function public.mod_reset_profile(uuid, text[], uuid, text, interval) from public, anon;
revoke execute on function public.mod_add_term(text, text, text, text) from public, anon;
revoke execute on function public.mod_remove_term(text) from public, anon;
revoke execute on function public.mod_terms() from public, anon;
revoke execute on function public.mod_check_text(text) from public, anon;
revoke execute on function public.moderation_summary() from public, anon;
grant execute on function public.mod_queue(text, integer) to authenticated, service_role;
grant execute on function public.mod_report(uuid) to authenticated, service_role;
grant execute on function public.mod_resolve_report(uuid, text, text) to authenticated, service_role;
grant execute on function public.mod_set_content_state(text, uuid, text, uuid, text, interval) to authenticated, service_role;
grant execute on function public.mod_suspend_user(uuid, timestamptz, text, uuid, boolean) to authenticated, service_role;
grant execute on function public.mod_unsuspend_user(uuid, text) to authenticated, service_role;
grant execute on function public.mod_reset_profile(uuid, text[], uuid, text, interval) to authenticated, service_role;
grant execute on function public.mod_add_term(text, text, text, text) to authenticated, service_role;
grant execute on function public.mod_remove_term(text) to authenticated, service_role;
grant execute on function public.mod_terms() to authenticated, service_role;
grant execute on function public.mod_check_text(text) to authenticated, service_role;
grant execute on function public.moderation_summary() to authenticated, service_role;

-- Worker functions: service role only.
revoke execute on function public.moderation_claim_deliveries(integer) from public, anon, authenticated;
revoke execute on function public.moderation_record_delivery(uuid[], boolean, text) from public, anon, authenticated;
revoke execute on function public.moderation_due_media(integer) from public, anon, authenticated;
revoke execute on function public.moderation_media_removed(text, text[], text) from public, anon, authenticated;
revoke execute on function public.moderation_purge() from public, anon, authenticated;
grant execute on function public.moderation_claim_deliveries(integer) to service_role;
grant execute on function public.moderation_record_delivery(uuid[], boolean, text) to service_role;
grant execute on function public.moderation_due_media(integer) to service_role;
grant execute on function public.moderation_media_removed(text, text[], text) to service_role;
grant execute on function public.moderation_purge() to service_role;
