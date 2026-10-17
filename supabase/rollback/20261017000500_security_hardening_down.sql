-- Reverts 20261017000500_security_hardening.sql. Restores the earlier,
-- weaker behaviour described in docs/SECURITY_REPORT.md; no data involved.

do $$
declare
  f record;
begin
  for f in select signature, via_public, via_anon from private.revoked_anon_execute loop
    if to_regprocedure(f.signature) is not null then
      if f.via_public then execute format('grant execute on function %s to public', f.signature); end if;
      if f.via_anon then execute format('grant execute on function %s to anon', f.signature); end if;
    end if;
  end loop;
end $$;
drop table if exists private.revoked_anon_execute;

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
