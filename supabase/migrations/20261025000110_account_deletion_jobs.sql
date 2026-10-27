-- Account deletion jobs: a deletion that has started always finishes.
--
-- delete-account records the request here before it removes anything, and
-- deletes the auth user last; this row goes with it (cascade), so a row that
-- exists is a deletion that hasn't finished. If Storage cleanup or the auth
-- delete fails, the row keeps the error and, for Sign in with Apple
-- accounts, the Apple token still to be revoked (the one-time code can't be
-- used twice). delete-account's scheduled run (x-pullup-cron-secret) picks up
-- rows whose last attempt is over ten minutes old and finishes them with the
-- service role, so it doesn't depend on the person opening the app again.
--
-- Once a deletion is requested the account can't upload files, so cleanup
-- isn't racing new uploads. Service role only; the table is never exposed.

create table private.account_deletions (
  user_id uuid primary key references auth.users (id) on delete cascade,
  requested_at timestamptz not null default now(),
  attempts integer not null default 0,
  last_attempt_at timestamptz,
  last_error text check (char_length(last_error) <= 500),
  apple_token text check (char_length(apple_token) <= 4096),
  apple_token_hint text check (apple_token_hint in ('refresh_token', 'access_token'))
);
alter table private.account_deletions enable row level security;
revoke all on private.account_deletions from public, anon, authenticated;

-- Uploads need an account that isn't being deleted.
create or replace function private.account_exists()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from auth.users u where u.id = auth.uid())
     and not exists (select 1 from private.account_deletions d where d.user_id = auth.uid());
$$;

-- Starts (or restarts) a deletion. Returns the Apple token kept from an
-- earlier attempt, if any.
create function public.account_deletion_begin(p_user uuid)
returns table (apple_token text, apple_token_hint text)
language sql
security definer
set search_path = ''
as $$
  insert into private.account_deletions as d (user_id, attempts, last_attempt_at)
  values (p_user, 1, now())
  on conflict (user_id) do update set attempts = d.attempts + 1, last_attempt_at = now()
  returning d.apple_token, d.apple_token_hint;
$$;

-- Records why an attempt stopped, and an Apple token to revoke later
-- (null keeps the one already stored).
create function public.account_deletion_failed(p_user uuid, p_error text, p_apple_token text default null, p_apple_token_hint text default null)
returns void
language sql
security definer
set search_path = ''
as $$
  update private.account_deletions
     set last_error = left(p_error, 500),
         apple_token = coalesce(p_apple_token, apple_token),
         apple_token_hint = case when p_apple_token is null then apple_token_hint else p_apple_token_hint end
   where user_id = p_user;
$$;

-- Unfinished deletions to retry, oldest attempt first.
create function public.account_deletions_due(p_limit integer default 20)
returns table (user_id uuid, attempts integer, requested_at timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select d.user_id, d.attempts, d.requested_at from private.account_deletions d
   where d.last_attempt_at is null or d.last_attempt_at < now() - interval '10 minutes'
   order by d.last_attempt_at nulls first
   limit least(greatest(p_limit, 1), 100);
$$;

revoke execute on function public.account_deletion_begin(uuid) from public, anon, authenticated;
revoke execute on function public.account_deletion_failed(uuid, text, text, text) from public, anon, authenticated;
revoke execute on function public.account_deletions_due(integer) from public, anon, authenticated;
grant execute on function public.account_deletion_begin(uuid) to service_role;
grant execute on function public.account_deletion_failed(uuid, text, text, text) to service_role;
grant execute on function public.account_deletions_due(integer) to service_role;
