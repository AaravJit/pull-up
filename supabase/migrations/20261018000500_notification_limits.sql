-- Security re-check, G4 (docs/SECURITY_REPORT.md).
--
-- Unliking and liking a post again, or unfollowing and following, created a
-- new notification (and push) every time, so one person could flood
-- another's phone. private.notify now:
--   * skips a like, follow, follow request or RSVP when the same person
--     already sent the same one in the last 24 hours, and
--   * sends at most 30 notifications an hour from one person to another
--     (comments included), dropping the rest.
-- Notifications from the server (drive validated, meet updates) don't go
-- through here and aren't limited.

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
  if k in ('like', 'follow', 'follow_request', 'meet_rsvp') and exists (
    select 1 from public.notifications n
    where n.recipient_id = recipient and n.actor_id = actor and n.kind = k
      and n.post_id is not distinct from post and n.meet_id is not distinct from meet
      and n.created_at > now() - interval '24 hours'
  ) then
    return;
  end if;
  if (select count(*) from public.notifications n
      where n.recipient_id = recipient and n.actor_id = actor
        and n.created_at > now() - interval '1 hour') >= 30 then
    return;
  end if;
  insert into public.notifications (recipient_id, actor_id, kind, post_id, meet_id)
  values (recipient, actor, k, post, meet);
end;
$$;
