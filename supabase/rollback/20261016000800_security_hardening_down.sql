-- Reverts 20261016000800_security_hardening.sql. Restores the earlier,
-- weaker behaviour described in docs/SECURITY_REPORT.md; no data involved.

select private.restore_anon_execute('20261016000800');
drop function private.restore_anon_execute(text);
drop function private.revoke_anon_execute(text);
drop table private.revoked_anon_execute;

create or replace function public.is_friend(a uuid, b uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.follows where follower_id = a and followee_id = b and status = 'accepted')
     and exists (select 1 from public.follows where follower_id = b and followee_id = a and status = 'accepted');
$$;

create or replace function public.is_blocked_between(a uuid, b uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.blocks
    where (blocker_id = a and blocked_id = b) or (blocker_id = b and blocked_id = a)
  );
$$;

grant execute on function private.validate_drive(uuid) to public;
grant execute on function private.notify(uuid, uuid, text, uuid, uuid) to public;
grant execute on function private.build_shared_route(uuid) to public;
