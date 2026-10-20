-- Reverses 20261018000500_notification_limits.sql: notify without limits.

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
