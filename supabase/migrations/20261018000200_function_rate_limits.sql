-- Per-account rate limits for edge functions that call out to Apple
-- (verify-subscription). A function asks for a slot with the service-role
-- key before doing any work; clients can't call this or read the log.

create table private.function_calls (
  user_id uuid not null references auth.users (id) on delete cascade,
  function_name text not null,
  called_at timestamptz not null default now()
);
create index function_calls_lookup on private.function_calls (user_id, function_name, called_at);
alter table private.function_calls enable row level security;

-- true and records the call when the account is under both limits;
-- false (and records nothing) when it isn't. Rows older than an hour are
-- removed as it goes, so the table stays small.
create or replace function public.take_function_slot(
  p_user uuid, p_function text, p_per_minute integer, p_per_hour integer
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  last_minute integer;
  last_hour integer;
begin
  -- One caller at a time per account and function, so parallel requests
  -- can't all slip under the limit.
  perform pg_advisory_xact_lock(hashtextextended(p_user::text || ':' || p_function, 0));
  delete from private.function_calls
  where user_id = p_user and function_name = p_function and called_at < now() - interval '1 hour';
  select count(*) filter (where called_at > now() - interval '1 minute'), count(*)
    into last_minute, last_hour
  from private.function_calls
  where user_id = p_user and function_name = p_function;
  if last_minute >= p_per_minute or last_hour >= p_per_hour then
    return false;
  end if;
  insert into private.function_calls (user_id, function_name) values (p_user, p_function);
  return true;
end;
$$;

revoke execute on function public.take_function_slot(uuid, text, integer, integer) from public, anon, authenticated;
grant execute on function public.take_function_slot(uuid, text, integer, integer) to service_role;
