-- Direct messages: one-to-one conversations with text, photos, reactions,
-- shared objects (vehicles, posts, meets, drive summaries), message
-- requests, read receipts, blocking, reporting and rate limits.
--
-- Security model
--   * A conversation has exactly two members, stored as a canonical pair
--     (user_a < user_b), so there is never more than one per pair and no
--     group chats.
--   * Nobody can read a conversation they are not in: every policy goes
--     through private.is_member. Membership rows are readable only by their
--     owner, so read times and mute state never leak; the peer's read time
--     is exposed only through inbox()/peer_read_at(), and only when both
--     people have read receipts on.
--   * Messages are inserted as yourself only (RLS), and a trigger enforces
--     blocks, request limits, rate limits, suspensions and that a shared
--     object is something the sender may see. Shared objects are re-checked
--     against the reader when previewed, so sharing never widens visibility.
--   * Messages can't be edited. A sender can unsend (body and media are
--     cleared, a tombstone remains for the other side's order of events).
--   * No locations: a shared drive is a summary only. Route geometry and GPS
--     tracks are never reachable through messages.

-- ---------------------------------------------------------------------------
-- Settings and moderation columns
-- ---------------------------------------------------------------------------

alter table public.privacy_settings
  -- Who may start a conversation with you. "everyone": people you don't
  -- follow land in Requests. "following": only people you follow.
  add column messages_from text not null default 'everyone'
    check (messages_from in ('everyone', 'following', 'nobody')),
  -- Reciprocal: you see others' read times only while yours are shared.
  add column dm_read_receipts boolean not null default true;

-- Set by Pull Up staff (service role) after a report is actioned.
alter table public.profiles add column messaging_suspended_until timestamptz;

create or replace function private.protect_profile_columns()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not private.is_trusted() then
    if tg_op = 'INSERT' then
      new.is_verified_organizer := false;
      new.onboarded_at := null;
      new.messaging_suspended_until := null;
    else
      new.is_verified_organizer := old.is_verified_organizer;
      new.onboarded_at := old.onboarded_at;
      new.messaging_suspended_until := old.messaging_suspended_until;
      new.id := old.id;
    end if;
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create table public.conversations (
  id uuid primary key default gen_random_uuid(),
  user_a uuid not null references public.profiles (id) on delete cascade,
  user_b uuid not null references public.profiles (id) on delete cascade,
  created_by uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  last_message_at timestamptz,
  unique (user_a, user_b),
  check (user_a < user_b),
  check (created_by in (user_a, user_b))
);
create index conversations_user_b_idx on public.conversations (user_b);
create index conversations_created_by_idx on public.conversations (created_by, created_at);

create table public.conversation_members (
  conversation_id uuid not null references public.conversations (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  -- request: someone you don't follow wrote first and you haven't answered.
  state text not null check (state in ('active', 'request', 'declined')),
  -- Hidden from the inbox until a newer message arrives.
  hidden_at timestamptz,
  -- "Delete conversation" for this member: earlier messages are gone for them.
  cleared_at timestamptz,
  last_read_at timestamptz,
  muted boolean not null default false,
  primary key (conversation_id, user_id)
);
create index conversation_members_user_idx on public.conversation_members (user_id, state);

create table public.messages (
  -- Client-generated, so a retry after a dropped connection can't duplicate.
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations (id) on delete cascade,
  sender_id uuid not null references public.profiles (id) on delete cascade,
  body text not null default '' check (char_length(body) <= 2000),
  media_path text,
  media_width integer check (media_width between 1 and 10000),
  media_height integer check (media_height between 1 and 10000),
  shared_kind text check (shared_kind in ('vehicle', 'post', 'meet', 'drive')),
  shared_id uuid,
  created_at timestamptz not null default now(),
  unsent_at timestamptz,
  check ((shared_kind is null) = (shared_id is null)),
  check (unsent_at is not null or char_length(btrim(body)) > 0 or media_path is not null or shared_id is not null)
);
create index messages_conversation_idx on public.messages (conversation_id, created_at desc);
create index messages_sender_idx on public.messages (sender_id, created_at desc);

create table public.message_reactions (
  message_id uuid not null references public.messages (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  emoji text not null check (emoji in ('👍', '❤️', '😂', '🔥', '😮', '😢', '🏁')),
  created_at timestamptz not null default now(),
  primary key (message_id, user_id)
);

create table public.reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references public.profiles (id) on delete cascade,
  subject_id uuid not null references public.profiles (id) on delete cascade,
  conversation_id uuid references public.conversations (id) on delete set null,
  message_id uuid references public.messages (id) on delete set null,
  reason text not null check (reason in ('spam', 'harassment', 'hate', 'sexual', 'violence', 'scam', 'impersonation', 'other')),
  details text not null default '' check (char_length(details) <= 1000),
  -- Copy of the reported message as the reporter saw it, so moderators can
  -- act even if it is later unsent.
  snapshot jsonb,
  status text not null default 'open' check (status in ('open', 'reviewing', 'actioned', 'dismissed')),
  created_at timestamptz not null default now(),
  check (reporter_id <> subject_id)
);
create index reports_status_idx on public.reports (status, created_at);
create index reports_reporter_idx on public.reports (reporter_id, created_at);

-- Notifications for messages (push only; the bell shows social activity).
alter table public.notifications add column conversation_id uuid references public.conversations (id) on delete cascade;
alter table public.notifications drop constraint notifications_kind_check;
alter table public.notifications add constraint notifications_kind_check
  check (kind in ('follow', 'follow_request', 'like', 'comment', 'meet_rsvp', 'meet_updated', 'meet_cancelled',
                  'meet_starting_soon', 'drive_validated', 'message', 'message_request'));

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

create or replace function private.is_member(p_conversation uuid, p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.conversations c
    where c.id = p_conversation and p_user in (c.user_a, c.user_b)
  );
$$;

create or replace function private.peer_of(p_conversation uuid, p_user uuid)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select case when c.user_a = p_user then c.user_b when c.user_b = p_user then c.user_a end
  from public.conversations c where c.id = p_conversation;
$$;

-- May the current user read this message? Member, not blocked, and not
-- before the point they cleared the conversation.
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

create or replace function private.can_view_shared(p_kind text, p_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select case p_kind
    when 'vehicle' then public.can_view_vehicle(p_id)
    when 'post' then public.can_view_post(p_id)
    when 'meet' then public.can_view_meet(p_id)
    when 'drive' then public.can_view_drive(p_id)
    else false
  end;
$$;

-- ---------------------------------------------------------------------------
-- Starting conversations
-- ---------------------------------------------------------------------------

-- Returns the conversation with p_user, creating it if needed. Every refusal
-- uses the same message, so it can't be used to learn who blocked whom or
-- who exists.
create or replace function public.start_conversation(p_user uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  a uuid;
  b uuid;
  conv uuid;
  allowed text;
  they_follow_me boolean;
begin
  if me is null then
    raise exception 'sign in first' using errcode = '42501';
  end if;
  if p_user is null or p_user = me
     or not exists (select 1 from public.profiles where id = p_user)
     or public.is_blocked_between(me, p_user) then
    raise exception 'you can''t message this person' using errcode = '42501';
  end if;
  if exists (select 1 from public.profiles where id = me and messaging_suspended_until > now()) then
    raise exception 'messaging is paused on your account' using errcode = '42501';
  end if;

  a := least(me, p_user);
  b := greatest(me, p_user);
  select id into conv from public.conversations where user_a = a and user_b = b;
  if conv is not null then
    -- Coming back to an existing conversation un-hides it for me.
    update public.conversation_members set hidden_at = null
    where conversation_id = conv and user_id = me;
    return conv;
  end if;

  select ps.messages_from into allowed from public.privacy_settings ps where ps.user_id = p_user;
  -- The recipient follows the sender: straight to their inbox. Otherwise it's a request.
  they_follow_me := exists (select 1 from public.follows where follower_id = p_user and followee_id = me and status = 'accepted');
  if allowed = 'nobody' or (allowed = 'following' and not they_follow_me) then
    raise exception 'you can''t message this person' using errcode = '42501';
  end if;

  -- Anti-spam: at most 20 new conversations a day.
  if (select count(*) from public.conversations where created_by = me and created_at > now() - interval '1 day') >= 20 then
    raise exception 'you''ve started a lot of conversations today; try again tomorrow' using errcode = '54000';
  end if;

  insert into public.conversations (user_a, user_b, created_by) values (a, b, me) returning id into conv;
  insert into public.conversation_members (conversation_id, user_id, state) values
    (conv, me, 'active'),
    (conv, p_user, case when they_follow_me then 'active' else 'request' end);
  return conv;
end;
$$;

-- ---------------------------------------------------------------------------
-- Sending
-- ---------------------------------------------------------------------------

create or replace function private.guard_message()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  peer uuid;
  my_state text;
  peer_state text;
  pending int;
begin
  if tg_op = 'UPDATE' then
    -- Only unsend_message changes messages, and only these columns.
    if new.id <> old.id or new.conversation_id <> old.conversation_id or new.sender_id <> old.sender_id
       or new.created_at <> old.created_at then
      raise exception 'messages can''t be edited' using errcode = '42501';
    end if;
    return new;
  end if;

  new.created_at := now();
  new.unsent_at := null;
  peer := private.peer_of(new.conversation_id, new.sender_id);
  if peer is null then
    raise exception 'not a member of this conversation' using errcode = '42501';
  end if;
  if public.is_blocked_between(new.sender_id, peer) then
    raise exception 'you can''t message this person' using errcode = '42501';
  end if;
  if exists (select 1 from public.profiles where id = new.sender_id and messaging_suspended_until > now()) then
    raise exception 'messaging is paused on your account' using errcode = '42501';
  end if;

  select state into my_state from public.conversation_members where conversation_id = new.conversation_id and user_id = new.sender_id;
  select state into peer_state from public.conversation_members where conversation_id = new.conversation_id and user_id = peer;
  if peer_state = 'declined' then
    raise exception 'you can''t message this person' using errcode = '42501';
  end if;
  -- Until a request is accepted, the sender gets three messages.
  if peer_state = 'request' then
    select count(*) into pending from public.messages
    where conversation_id = new.conversation_id and sender_id = new.sender_id;
    if pending >= 3 then
      raise exception 'wait for them to accept your request' using errcode = '54000';
    end if;
  end if;

  -- Rate limits: 30 messages a minute, 10 photos a minute.
  if (select count(*) from public.messages where sender_id = new.sender_id and created_at > now() - interval '1 minute') >= 30 then
    raise exception 'slow down a little' using errcode = '54000';
  end if;
  if new.media_path is not null then
    if (select count(*) from public.messages where sender_id = new.sender_id and media_path is not null
        and created_at > now() - interval '1 minute') >= 10 then
      raise exception 'slow down a little' using errcode = '54000';
    end if;
    -- Photos must be the sender's own upload into this conversation's folder.
    if split_part(new.media_path, '/', 1) <> new.conversation_id::text
       or split_part(new.media_path, '/', 2) <> new.sender_id::text then
      raise exception 'photo must be uploaded to this conversation' using errcode = '42501';
    end if;
  end if;

  -- You can only share what you can see yourself.
  if new.shared_kind is not null then
    if not private.can_view_shared(new.shared_kind, new.shared_id) then
      raise exception 'you can''t share that' using errcode = '42501';
    end if;
  end if;

  -- Replying to a request accepts it.
  if my_state = 'request' then
    update public.conversation_members set state = 'active' where conversation_id = new.conversation_id and user_id = new.sender_id;
  end if;
  return new;
end;
$$;

create trigger messages_guard before insert or update on public.messages
  for each row execute function private.guard_message();

create or replace function private.after_message()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  peer uuid := private.peer_of(new.conversation_id, new.sender_id);
  peer_state text;
  peer_muted boolean;
begin
  update public.conversations set last_message_at = new.created_at where id = new.conversation_id;
  -- A new message brings a hidden conversation back for both people.
  update public.conversation_members set hidden_at = null
  where conversation_id = new.conversation_id and hidden_at is not null;
  update public.conversation_members set last_read_at = new.created_at
  where conversation_id = new.conversation_id and user_id = new.sender_id;

  select state, muted into peer_state, peer_muted from public.conversation_members
  where conversation_id = new.conversation_id and user_id = peer;
  if not coalesce(peer_muted, false) then
    insert into public.notifications (recipient_id, actor_id, kind, conversation_id)
    values (peer, new.sender_id, case when peer_state = 'request' then 'message_request' else 'message' end, new.conversation_id);
  end if;
  return new;
end;
$$;

create trigger messages_after after insert on public.messages
  for each row execute function private.after_message();

-- ---------------------------------------------------------------------------
-- Conversation actions
-- ---------------------------------------------------------------------------

create or replace function public.mark_conversation_read(p_conversation uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.conversation_members set last_read_at = now()
  where conversation_id = p_conversation and user_id = auth.uid();
  delete from public.notifications
  where recipient_id = auth.uid() and conversation_id = p_conversation;
end;
$$;

create or replace function public.respond_to_request(p_conversation uuid, p_accept boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.conversation_members
  set state = case when p_accept then 'active' else 'declined' end,
      hidden_at = case when p_accept then null else now() end
  where conversation_id = p_conversation and user_id = auth.uid() and state in ('request', 'declined');
  if not found then
    raise exception 'no such request' using errcode = '42501';
  end if;
end;
$$;

create or replace function public.set_conversation_muted(p_conversation uuid, p_muted boolean)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.conversation_members set muted = p_muted
  where conversation_id = p_conversation and user_id = auth.uid();
$$;

-- Hide: out of the inbox until a new message. Delete: hide and clear the
-- history for me; the other person keeps their copy.
create or replace function public.hide_conversation(p_conversation uuid, p_clear boolean default false)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.conversation_members
  set hidden_at = now(), cleared_at = case when p_clear then now() else cleared_at end
  where conversation_id = p_conversation and user_id = auth.uid();
$$;

create or replace function public.unsend_message(p_message uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.messages
  set unsent_at = now(), body = '', media_path = null, media_width = null, media_height = null,
      shared_kind = null, shared_id = null
  where id = p_message and sender_id = auth.uid() and unsent_at is null;
  if not found then
    raise exception 'you can only unsend your own messages' using errcode = '42501';
  end if;
  delete from public.message_reactions where message_id = p_message;
end;
$$;

-- The peer's read time, when both people share read receipts.
create or replace function public.peer_read_at(p_conversation uuid)
returns timestamptz
language sql
stable
security definer
set search_path = ''
as $$
  select peer.last_read_at
  from public.conversation_members peer
  join public.privacy_settings peer_ps on peer_ps.user_id = peer.user_id
  join public.privacy_settings my_ps on my_ps.user_id = auth.uid()
  where peer.conversation_id = p_conversation
    and peer.user_id = private.peer_of(p_conversation, auth.uid())
    and peer_ps.dm_read_receipts and my_ps.dm_read_receipts
    and not public.is_blocked_between(peer.user_id, auth.uid());
$$;

-- Inbox page: conversations in one state ('active' or 'request'), newest
-- first, keyset paged by last_message_at.
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

-- Badge counts for the inbox button.
create or replace function public.unread_message_counts()
returns table (unread_conversations integer, requests integer)
language sql
stable
security definer
set search_path = ''
as $$
  select
    (select count(*)::int from public.inbox('active', null, 50) i where i.unread_count > 0),
    (select count(*)::int from public.inbox('request', null, 50));
$$;

-- What a shared object looks like inside a message, checked against the
-- reader right now. Never includes locations or route geometry.
create or replace function public.shared_preview(p_kind text, p_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  result jsonb;
begin
  if auth.uid() is null or not private.can_view_shared(p_kind, p_id) then
    return jsonb_build_object('kind', p_kind, 'id', p_id, 'available', false);
  end if;
  if p_kind = 'vehicle' then
    select jsonb_build_object(
      'kind', 'vehicle', 'id', v.id, 'available', true,
      'title', v.year || ' ' || v.make || ' ' || v.model,
      'subtitle', nullif(btrim(v.nickname || case when v.trim <> '' then ' · ' || v.trim else '' end, ' ·'), ''),
      'image_path', v.cover_photo_path, 'vehicle_kind', v.kind, 'body_style', v.body_style,
      'identity_color', v.identity_color, 'owner_id', v.owner_id, 'owner_username', p.username)
    into result from public.vehicles v join public.profiles p on p.id = v.owner_id where v.id = p_id;
  elsif p_kind = 'post' then
    select jsonb_build_object(
      'kind', 'post', 'id', po.id, 'available', true,
      'title', '@' || p.username, 'subtitle', left(po.caption, 140),
      'image_path', (select pm.storage_path from public.post_media pm where pm.post_id = po.id and pm.media_type = 'image' order by pm.position limit 1),
      'owner_id', po.author_id, 'owner_username', p.username)
    into result from public.posts po join public.profiles p on p.id = po.author_id where po.id = p_id;
  elsif p_kind = 'meet' then
    select jsonb_build_object(
      'kind', 'meet', 'id', m.id, 'available', true,
      'title', m.title, 'subtitle', m.venue_name, 'starts_at', m.starts_at,
      'cancelled', m.cancelled_at is not null, 'owner_id', m.host_id, 'owner_username', p.username)
    into result from public.meets m join public.profiles p on p.id = m.host_id where m.id = p_id;
  elsif p_kind = 'drive' then
    select jsonb_build_object(
      'kind', 'drive', 'id', d.id, 'available', true,
      'title', d.title, 'distance_m', d.distance_m, 'moving_s', d.moving_s,
      'vehicle_title', (select v.year || ' ' || v.make || ' ' || v.model from public.vehicles v
                        where v.id = d.vehicle_id and public.can_view_vehicle(v.id)),
      'owner_id', d.owner_id, 'owner_username', p.username)
    into result from public.drives d join public.profiles p on p.id = d.owner_id where d.id = p_id;
  end if;
  return coalesce(result, jsonb_build_object('kind', p_kind, 'id', p_id, 'available', false));
end;
$$;

-- ---------------------------------------------------------------------------
-- Reports (moderation hook)
-- ---------------------------------------------------------------------------

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

-- ---------------------------------------------------------------------------
-- Retention
-- ---------------------------------------------------------------------------

-- Run daily by the dm-retention function (service role). Returns the storage
-- paths whose messages it deleted so the function can remove the files.
--   * requests nobody answered within 30 days are deleted;
--   * messages both people deleted ("cleared") are deleted;
--   * unsent-message tombstones are deleted after 30 days;
--   * closed reports are deleted after a year.
create or replace function public.dm_purge()
returns table (media_path text)
language plpgsql
security definer
set search_path = ''
as $$
begin
  create temporary table if not exists pg_temp.dm_purged (media_path text) on commit drop;
  delete from pg_temp.dm_purged;

  with stale as (
    select c.id from public.conversations c
    join public.conversation_members cm on cm.conversation_id = c.id
    where cm.state in ('request', 'declined') and c.created_at < now() - interval '30 days'
    group by c.id
  ), gone as (
    delete from public.messages m using stale where m.conversation_id = stale.id returning m.media_path
  )
  insert into pg_temp.dm_purged select g.media_path from gone g where g.media_path is not null;
  delete from public.conversations c
  where exists (select 1 from public.conversation_members cm where cm.conversation_id = c.id and cm.state in ('request', 'declined'))
    and c.created_at < now() - interval '30 days';

  with gone as (
    delete from public.messages m
    where m.created_at <= (select min(coalesce(cm.cleared_at, '-infinity'::timestamptz))
                           from public.conversation_members cm where cm.conversation_id = m.conversation_id)
    returning m.media_path
  )
  insert into pg_temp.dm_purged select g.media_path from gone g where g.media_path is not null;

  delete from public.messages where unsent_at < now() - interval '30 days';
  delete from public.reports where status in ('actioned', 'dismissed') and created_at < now() - interval '1 year';

  return query select p.media_path from pg_temp.dm_purged p;
end;
$$;

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------

alter table public.conversations enable row level security;
alter table public.conversation_members enable row level security;
alter table public.messages enable row level security;
alter table public.message_reactions enable row level security;
alter table public.reports enable row level security;

create policy "Conversations: members read"
  on public.conversations for select to authenticated
  using (auth.uid() in (user_a, user_b));
-- No insert/update/delete policies: start_conversation is the only way in.

create policy "Members: own row"
  on public.conversation_members for select to authenticated
  using (user_id = auth.uid());

create policy "Messages: members read what they haven't cleared"
  on public.messages for select to authenticated
  using (private.can_read_message(id));
create policy "Messages: send as yourself into your conversations"
  on public.messages for insert to authenticated
  with check (sender_id = auth.uid() and private.is_member(conversation_id, auth.uid()));

create policy "Reactions: visible with the message"
  on public.message_reactions for select to authenticated
  using (private.can_read_message(message_id));
create policy "Reactions: react as yourself"
  on public.message_reactions for insert to authenticated
  with check (user_id = auth.uid() and private.can_read_message(message_id));
create policy "Reactions: change your reaction"
  on public.message_reactions for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid() and private.can_read_message(message_id));
create policy "Reactions: remove your reaction"
  on public.message_reactions for delete to authenticated
  using (user_id = auth.uid());

create policy "Reports: your own"
  on public.reports for select to authenticated
  using (reporter_id = auth.uid());
-- Reports are filed through report_user; staff use the service role.

-- Columns a client may never write directly.
revoke update on public.messages from authenticated;
revoke insert, update, delete on public.conversations from authenticated;
revoke insert, update, delete on public.conversation_members from authenticated;
revoke insert, update, delete on public.reports from authenticated;

-- ---------------------------------------------------------------------------
-- Storage: dm-media/<conversation>/<sender>/<file>
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('dm-media', 'dm-media', false, 10485760, array['image/jpeg', 'image/png', 'image/heic', 'image/webp'])
on conflict (id) do nothing;

create or replace function private.dm_path_member(p_name text, p_user uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  conv uuid;
begin
  begin
    conv := split_part(p_name, '/', 1)::uuid;
  exception when invalid_text_representation then
    return false;
  end;
  return private.is_member(conv, p_user);
end;
$$;

create policy "DM media: upload into your conversations"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'dm-media'
    and split_part(name, '/', 2) = auth.uid()::text
    and private.dm_path_member(name, auth.uid())
  );
create policy "DM media: sender removes own files"
  on storage.objects for delete to authenticated
  using (bucket_id = 'dm-media' and split_part(name, '/', 2) = auth.uid()::text);
create policy "DM media: readable with the message"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'dm-media'
    and (
      (split_part(name, '/', 2) = auth.uid()::text and private.dm_path_member(name, auth.uid()))
      or exists (select 1 from public.messages m where m.media_path = name and private.can_read_message(m.id))
    )
  );

-- ---------------------------------------------------------------------------
-- Realtime and grants
-- ---------------------------------------------------------------------------

-- Postgres Changes respects the select policies above, so a subscriber only
-- receives rows they could read anyway.
do $$
begin
  alter publication supabase_realtime add table public.messages, public.message_reactions;
exception when undefined_object then
  raise notice 'supabase_realtime publication not found; realtime for messages not enabled';
end $$;

revoke execute on function public.start_conversation(uuid) from public, anon;
revoke execute on function public.mark_conversation_read(uuid) from public, anon;
revoke execute on function public.respond_to_request(uuid, boolean) from public, anon;
revoke execute on function public.set_conversation_muted(uuid, boolean) from public, anon;
revoke execute on function public.hide_conversation(uuid, boolean) from public, anon;
revoke execute on function public.unsend_message(uuid) from public, anon;
revoke execute on function public.peer_read_at(uuid) from public, anon;
revoke execute on function public.inbox(text, timestamptz, integer) from public, anon;
revoke execute on function public.unread_message_counts() from public, anon;
revoke execute on function public.shared_preview(text, uuid) from public, anon;
revoke execute on function public.report_user(uuid, text, text, uuid) from public, anon;
revoke execute on function public.dm_purge() from public, anon, authenticated;
grant execute on function public.start_conversation(uuid) to authenticated;
grant execute on function public.mark_conversation_read(uuid) to authenticated;
grant execute on function public.respond_to_request(uuid, boolean) to authenticated;
grant execute on function public.set_conversation_muted(uuid, boolean) to authenticated;
grant execute on function public.hide_conversation(uuid, boolean) to authenticated;
grant execute on function public.unsend_message(uuid) to authenticated;
grant execute on function public.peer_read_at(uuid) to authenticated;
grant execute on function public.inbox(text, timestamptz, integer) to authenticated;
grant execute on function public.unread_message_counts() to authenticated;
grant execute on function public.shared_preview(text, uuid) to authenticated;
grant execute on function public.report_user(uuid, text, text, uuid) to authenticated;
grant execute on function public.dm_purge() to service_role;
