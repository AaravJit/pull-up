-- Reverts 20261018000300_push_guard.sql: push_content as defined in
-- 20261017000400_notification_preferences.sql. No data is touched.

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
