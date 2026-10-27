-- Profile search as an RPC, so the search term travels in the POST body
-- instead of the request URL. The API gateway logs request URLs (path and
-- query string), so a `profiles?username=ilike.<term>*` GET left every
-- search term in the provider's logs; RPC arguments in the body aren't
-- logged there. That keeps search terms out of "Search History" for the
-- App Privacy label (docs/submission/PRIVACY_INVENTORY.md).
--
-- Security invoker: the caller's own RLS on profiles applies, exactly as
-- for the old direct select (signed-in users only, blocked pairs hidden).

create or replace function public.search_profiles(p_prefix text)
returns table (id uuid, username text, display_name text, avatar_path text)
language sql
stable
security invoker
set search_path = ''
as $$
  select p.id, p.username::text, p.display_name, p.avatar_path
  from public.profiles p
  where length(btrim(coalesce(p_prefix, ''))) >= 2
    -- A prefix match on the literal text: escape LIKE's wildcards.
    and p.username ilike replace(replace(replace(lower(btrim(p_prefix)), '\', '\\'), '%', '\%'), '_', '\_') || '%'
  order by p.username
  limit 20;
$$;

revoke all on function public.search_profiles(text) from public, anon;
grant execute on function public.search_profiles(text) to authenticated, service_role;
