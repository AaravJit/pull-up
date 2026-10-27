-- Reverts 20261025000330_messaging_pause_private.sql: messaging pauses go
-- back into profiles.messaging_suspended_until (their notes are dropped) and
-- the functions return to their earlier definitions.

alter table public.profiles drop constraint if exists profiles_messaging_suspension_moved;
comment on column public.profiles.messaging_suspended_until is null;

update public.profiles p set messaging_suspended_until = m.paused_until
from private.messaging_pauses m where m.user_id = p.id;

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


drop trigger if exists messaging_pauses_audit on private.messaging_pauses;
drop function if exists private.audit_messaging_pauses();
drop function if exists private.messaging_paused(uuid);
drop table if exists private.messaging_pauses;
