-- Push notification preferences, and device token registration that follows
-- the signed-in account.
--
-- * Preferences are per category and stored on the server, because the
--   server decides whether to push (send-push asks push_content below). They
--   only affect pushes: the in-app activity list and inbox are unchanged.
-- * Message previews are off by default. With them off a push says who wrote,
--   never what. They are never shown for message requests, whatever the
--   setting, so a stranger's text can't appear on a lock screen.
-- * Device tokens are registered through register_device_token only. When
--   someone signs in on a phone that another account used, the token moves
--   to the new account, so the previous account's pushes stop arriving
--   there. (Before this, the direct upsert failed RLS on the other account's
--   row and the old account kept the token.)
--
-- Reversible: supabase/rollback/20261017000400_notification_preferences_down.sql.
-- Nothing existing is dropped or rewritten.

create table public.notification_preferences (
  user_id uuid primary key default auth.uid() references public.profiles (id) on delete cascade,
  -- Messages in conversations you've accepted.
  messages boolean not null default true,
  -- First messages from people you don't follow.
  message_requests boolean not null default true,
  -- Likes and comments on your posts.
  likes_comments boolean not null default true,
  -- New followers and follow requests.
  followers boolean not null default true,
  -- RSVPs, changes and reminders for meets.
  meets boolean not null default true,
  -- A drive finished checking.
  drives boolean not null default true,
  -- Show message text in pushes (accepted conversations only).
  message_previews boolean not null default false,
  updated_at timestamptz not null default now()
);

create trigger notification_preferences_touch before update on public.notification_preferences
  for each row execute function private.touch_updated_at();

alter table public.notification_preferences enable row level security;

create policy "Notification preferences: own reads"
  on public.notification_preferences for select to authenticated using (user_id = auth.uid());
create policy "Notification preferences: own creates"
  on public.notification_preferences for insert to authenticated with check (user_id = auth.uid());
create policy "Notification preferences: own updates"
  on public.notification_preferences for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

revoke all on public.notification_preferences from anon;
revoke delete, truncate on public.notification_preferences from authenticated;

-- Which preference governs a notification kind. Unknown kinds (future
-- account and security notices) have no switch and are always pushed.
create or replace function private.push_category(p_kind text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_kind = 'message' then 'messages'
    when p_kind = 'message_request' then 'message_requests'
    when p_kind in ('like', 'comment') then 'likes_comments'
    when p_kind in ('follow', 'follow_request') then 'followers'
    when p_kind in ('meet_rsvp', 'meet_updated', 'meet_cancelled', 'meet_starting_soon') then 'meets'
    when p_kind = 'drive_validated' then 'drives'
    else null
  end;
$$;

-- What send-push may send for one notification: whether the recipient wants
-- it pushed, the actor's name, and the message text only when previews are
-- on and the conversation is accepted. Server only.
create or replace function public.push_content(p_notification uuid)
returns table (
  recipient_id uuid,
  kind text,
  conversation_id uuid,
  already_pushed boolean,
  allowed boolean,
  actor_name text,
  preview text
)
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  n public.notifications;
  prefs public.notification_preferences;
  has_prefs boolean;
  category text;
  wanted boolean := true;
  name text;
  body text;
begin
  if not private.is_trusted() then
    raise exception 'push_content is server only' using errcode = '42501';
  end if;
  select * into n from public.notifications where id = p_notification;
  if not found then return; end if;

  select * into prefs from public.notification_preferences p where p.user_id = n.recipient_id;
  has_prefs := found;
  category := private.push_category(n.kind);
  if has_prefs and category is not null then
    wanted := case category
      when 'messages' then prefs.messages
      when 'message_requests' then prefs.message_requests
      when 'likes_comments' then prefs.likes_comments
      when 'followers' then prefs.followers
      when 'meets' then prefs.meets
      when 'drives' then prefs.drives
      else true
    end;
  end if;

  if n.actor_id is not null then
    select coalesce(nullif(btrim(pr.display_name), ''), '@' || pr.username) into name
    from public.profiles pr where pr.id = n.actor_id;
  end if;

  if wanted and n.kind = 'message' and has_prefs and prefs.message_previews and n.conversation_id is not null then
    -- The newest message the actor had sent when the notification was made,
    -- if it hasn't been unsent since and the recipient has accepted.
    select case
             when m.media_path is not null and btrim(m.body) = '' then 'Sent a photo'
             when m.shared_kind is not null and btrim(m.body) = '' then 'Shared a ' || m.shared_kind
             else left(regexp_replace(btrim(m.body), '\s+', ' ', 'g'), 120)
           end
      into body
    from public.messages m
    join public.conversation_members cm
      on cm.conversation_id = m.conversation_id and cm.user_id = n.recipient_id and cm.state = 'active'
    where m.conversation_id = n.conversation_id
      and m.sender_id = n.actor_id
      and m.created_at <= n.created_at
      and m.unsent_at is null
    order by m.created_at desc
    limit 1;
  end if;

  return query select n.recipient_id, n.kind, n.conversation_id, n.pushed_at is not null, wanted, name, body;
end;
$$;

revoke execute on function public.push_content(uuid) from public, anon, authenticated;
grant execute on function public.push_content(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- Device tokens
-- ---------------------------------------------------------------------------

drop policy "Device tokens: own" on public.device_tokens;
create policy "Device tokens: own reads"
  on public.device_tokens for select to authenticated using (user_id = auth.uid());
create policy "Device tokens: own removes"
  on public.device_tokens for delete to authenticated using (user_id = auth.uid());
revoke insert, update on public.device_tokens from anon, authenticated;

-- Registers this phone's APNs token for the caller. A token belongs to one
-- app install, so the latest account to register it owns it. Each account
-- keeps its 10 most recently registered phones.
create or replace function public.register_device_token(p_token text, p_environment text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  v_token text := lower(btrim(coalesce(p_token, '')));
begin
  if me is null then
    raise exception 'sign in to register for notifications' using errcode = '42501';
  end if;
  if v_token !~ '^([0-9a-f]{2}){32,100}$' then
    raise exception 'not an APNs device token' using errcode = '22023';
  end if;
  if p_environment is null or p_environment not in ('sandbox', 'production') then
    raise exception 'environment must be sandbox or production' using errcode = '22023';
  end if;

  insert into public.device_tokens (token, user_id, platform, environment, updated_at)
  values (v_token, me, 'ios', p_environment, now())
  on conflict on constraint device_tokens_pkey do update
    set user_id = excluded.user_id, platform = 'ios', environment = excluded.environment, updated_at = now();

  delete from public.device_tokens d
  where d.user_id = me
    and d.token in (
      select t.token from public.device_tokens t where t.user_id = me
      order by t.updated_at desc offset 10
    );
end;
$$;

-- Called on sign-out, so a shared phone stops getting the account's pushes.
create or replace function public.unregister_device_token(p_token text)
returns void
language sql
security invoker
set search_path = ''
as $$
  delete from public.device_tokens where token = lower(btrim(p_token)) and user_id = auth.uid();
$$;

revoke execute on function public.register_device_token(text, text) from public, anon;
revoke execute on function public.unregister_device_token(text) from public, anon;
grant execute on function public.register_device_token(text, text) to authenticated;
grant execute on function public.unregister_device_token(text) to authenticated;
