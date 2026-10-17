-- Reverts 20261017000500_security_hardening.sql. Restores the earlier,
-- weaker behaviour described in docs/SECURITY_REPORT.md; no data involved.

select private.restore_anon_execute('20261017000500');

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
