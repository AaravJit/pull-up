-- Fixes from the Phase 2 security assessment (docs/SECURITY_REPORT.md).
-- Regression tests: supabase/tests/006_security_surface.sql.
--
-- SEC-01  Internal helpers that run with owner rights were callable by any
--         signed-in user: build_shared_route (the trimmed route of anyone's
--         drive, private ones included), notify (a notification "from"
--         anyone to anyone, which send-push would then push) and
--         validate_drive. Only the owner-rights triggers and functions that
--         call them need them, so callers lose EXECUTE.
-- SEC-02  is_blocked_between and is_friend answered for any two people, so
--         anyone could learn who blocked whom, or that two private accounts
--         are friends. They now answer only when the caller is one of the
--         two (or the server, with no signed-in user).
-- SEC-03  private.peer_of and private.is_member, used by DM policies, answer
--         only about the caller. (Exploiting them needed a conversation id,
--         which strangers can't list; this is defence in depth.)
-- SEC-04  Postgres grants EXECUTE to PUBLIC by default, so signed-out (anon)
--         callers could run every public function. Nothing in the app calls
--         the API signed out, and every policy is for authenticated users, so
--         anon loses EXECUTE on all of them. Exactly what was revoked is kept
--         in private.revoked_anon_execute so the rollback restores it.
--
-- Reversible: supabase/rollback/20261017000500_security_hardening_down.sql.
-- No data is touched.

-- SEC-01 ----------------------------------------------------------------------
revoke execute on function private.build_shared_route(uuid) from public, anon, authenticated;
revoke execute on function private.notify(uuid, uuid, text, uuid, uuid) from public, anon, authenticated;
revoke execute on function private.validate_drive(uuid) from public, anon, authenticated;

-- SEC-02 ----------------------------------------------------------------------
-- Inside owner-rights code (policies' helpers, triggers) auth.uid() is still
-- the person making the request, and every caller passes them as a or b.
create or replace function public.is_blocked_between(a uuid, b uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when auth.uid() is not null and auth.uid() is distinct from a and auth.uid() is distinct from b then false
    else exists (
      select 1 from public.blocks
      where (blocker_id = a and blocked_id = b) or (blocker_id = b and blocked_id = a)
    )
  end;
$$;

create or replace function public.is_friend(a uuid, b uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when auth.uid() is not null and auth.uid() is distinct from a and auth.uid() is distinct from b then false
    else exists (select 1 from public.follows where follower_id = a and followee_id = b and status = 'accepted')
     and exists (select 1 from public.follows where follower_id = b and followee_id = a and status = 'accepted')
  end;
$$;

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
create table private.revoked_anon_execute (
  signature text primary key,
  -- Who held the grant: PUBLIC, anon itself, or both.
  via_public boolean not null,
  via_anon boolean not null,
  revoked_at timestamptz not null default now()
);
revoke all on private.revoked_anon_execute from public, anon, authenticated;

do $$
declare
  f record;
  public_had boolean;
  anon_had boolean;
begin
  for f in
    select p.oid, p.oid::regprocedure::text as signature
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prokind = 'f'
      and p.prorettype <> 'trigger'::regtype
      and has_function_privilege('anon', p.oid, 'execute')
      -- Extension-owned functions (none today) are left to their extension.
      and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
  loop
    select coalesce(bool_or(a.grantee = 0), false), coalesce(bool_or(a.grantee = 'anon'::regrole::oid), false)
    into public_had, anon_had
    from pg_proc p,
         aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
    where p.oid = f.oid and a.privilege_type = 'EXECUTE';
    insert into private.revoked_anon_execute (signature, via_public, via_anon) values (f.signature, public_had, anon_had);
    -- Signed-in users and the server keep what they had through PUBLIC.
    if has_function_privilege('authenticated', f.oid, 'execute') then
      execute format('grant execute on function %s to authenticated', f.signature);
    end if;
    if has_function_privilege('service_role', f.oid, 'execute') then
      execute format('grant execute on function %s to service_role', f.signature);
    end if;
    execute format('revoke execute on function %s from public, anon', f.signature);
  end loop;
end $$;
