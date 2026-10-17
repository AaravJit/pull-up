-- Phase 2 part of the security assessment (docs/SECURITY_REPORT.md).
-- SEC-01, SEC-02 and SEC-04 for the Phase 1 schema are fixed in
-- 20261016000800_security_hardening.sql; this covers the Phase 2 code.
-- Regression tests: supabase/tests/006_security_surface.sql.
--
-- SEC-03  private.peer_of and private.is_member, used by DM policies, answer
--         only about the caller. (Exploiting them needed a conversation id,
--         which strangers can't list; this is defence in depth.)
-- SEC-04  The public functions added since 20261016000800 (accounts,
--         messages, Pro, push) got Postgres' default PUBLIC grant, so
--         signed-out callers could run them. Anon loses EXECUTE on them the
--         same way, recorded under this migration for the rollback.
--
-- Reversible: supabase/rollback/20261017000500_security_hardening_down.sql.
-- No data is touched.

-- SEC-03 ----------------------------------------------------------------------
create or replace function private.peer_of(p_conversation uuid, p_user uuid)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select case when c.user_a = p_user then c.user_b when c.user_b = p_user then c.user_a end
  from public.conversations c
  where c.id = p_conversation and (auth.uid() is null or auth.uid() = p_user);
$$;

create or replace function private.is_member(p_conversation uuid, p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select (auth.uid() is null or auth.uid() = p_user) and exists (
    select 1 from public.conversations c
    where c.id = p_conversation and p_user in (c.user_a, c.user_b)
  );
$$;

-- SEC-04 ----------------------------------------------------------------------
select private.revoke_anon_execute('20261017000500');
