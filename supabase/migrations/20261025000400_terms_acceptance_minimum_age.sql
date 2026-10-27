-- Versioned acceptance of the terms and community guidelines, and the
-- minimum-age check, both enforced by the database.
-- supabase/tests/040_terms_acceptance.sql and 041_minimum_age.sql are the proof.
--
-- Records
--   public.terms_versions     Published versions of the service terms and the
--                             community guidelines (docs/public/terms.md and
--                             community.md), which are accepted together. The
--                             version is the pages' "Last updated" date.
--                             Exactly one is current. Signed-in users can read
--                             them; only a migration changes them.
--   public.terms_acceptances  Which version each account accepted, and when
--                             (the server's clock; a client can't backdate it).
--                             Row-level security: an account reads only its own
--                             rows and adds only its own acceptance of the
--                             current version. No updates or deletes; the rows
--                             are deleted with the account.
--   private.age_checks        The outcome of the minimum-age check for each
--                             account: whether it meets the minimum, the
--                             minimum it was checked against, how it was
--                             checked, and when. Never a birth date or an age.
--                             Clients can't read or write it directly.
--
-- API (signed in only)
--   my_consent_status()            What the app needs to pick its screen.
--   accept_terms(p_version)        Accepts the current version (RLS applies).
--   record_age_check(p_meets_minimum)
--     Records the answer once. A "doesn't meet the minimum" answer can't be
--     changed through the API (support can, in the SQL editor); a passing
--     answer can still be lowered. A failing answer also makes the profile
--     private, turns off messages from anyone and leaves the leaderboards.
--
-- What the age check is, honestly
--   method 'self_declared': the app asks for a date of birth on the phone,
--   works out whether the person meets the minimum, and sends only that
--   yes/no. Nothing verifies it. It keeps out people who answer truthfully and
--   records that the question was asked; it does not stop someone who enters
--   a false date, and it is not age assurance or verification. Apple's
--   Declared Age Range API (iOS 26+, needs an entitlement) would be a second
--   method later; it would also be reported by the app, not verified here.
--
-- Enforcement
--   Until an account has a passing age check and has accepted the current
--   version, it can't add or change anything other people can see or that
--   reaches them, whichever API it uses: its profile (username, name, photo,
--   bio), vehicles, mods, vehicle photos, posts, post media, likes, comments,
--   meets, RSVPs, follows, message requests (conversations), messages,
--   reactions and newly shared routes, and it can't upload files. The write
--   fails with SQLSTATE PUC02 (age) or PUC01 (terms) and a sentence the app
--   shows. Still allowed: reading, deleting its own things, making them less
--   visible, cancelling a meet, unsending a message, privacy settings,
--   blocking, reporting, recording drives (private by default; the phone's
--   upload queue retries them), signing out and deleting the account. The
--   server itself (no signed-in user: the sign-up hook, the service role, the
--   SQL editor) isn't affected.
--   Trigger names end in _consent_required and the SQLSTATEs are PUC01/PUC02,
--   separate from moderation's (_active_account, _moderation_filter, PUM01,
--   PUM02, 20261025000300-320), so the two compose.
--
-- Publishing new terms
--   Edit docs/public/terms.md / community.md, then in a new migration:
--     update public.terms_versions set is_current = false where is_current;
--     insert into public.terms_versions (version, summary, is_current)
--     values ('YYYY-MM-DD', 'One or two sentences on what changed.', true);
--   Every account is then asked to accept again and can't publish until it
--   has. Raising the minimum age is a change to private.minimum_age(): checks
--   made against a lower minimum then stop counting and the app asks again.
--
-- Reversible: supabase/rollback/20261025000400_terms_acceptance_minimum_age_down.sql.

-- ---------------------------------------------------------------------------
-- Terms versions and acceptances
-- ---------------------------------------------------------------------------

create table public.terms_versions (
  version text primary key check (version ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'),
  -- Shown to people asked to accept again; empty for the first version.
  summary text not null default '' check (char_length(summary) <= 500),
  is_current boolean not null default false,
  published_at timestamptz not null default now()
);
create unique index terms_versions_one_current on public.terms_versions (is_current) where is_current;
alter table public.terms_versions enable row level security;
create policy "Terms versions: signed-in users can read them"
  on public.terms_versions for select to authenticated using (true);
revoke all on public.terms_versions from anon, authenticated;
grant select on public.terms_versions to authenticated;
grant select, insert, update on public.terms_versions to service_role;

-- docs/public/terms.md and community.md, "Last updated: October 27, 2026".
insert into public.terms_versions (version, summary, is_current) values ('2026-10-27', '', true);

create table public.terms_acceptances (
  user_id uuid not null references public.profiles (id) on delete cascade,
  version text not null references public.terms_versions (version),
  accepted_at timestamptz not null default now(),
  primary key (user_id, version)
);
alter table public.terms_acceptances enable row level security;
create policy "Terms acceptances: read your own"
  on public.terms_acceptances for select to authenticated using (user_id = auth.uid());
create policy "Terms acceptances: accept the current version yourself"
  on public.terms_acceptances for insert to authenticated
  with check (user_id = auth.uid() and version = (select v.version from public.terms_versions v where v.is_current));
revoke all on public.terms_acceptances from anon, authenticated;
grant select, insert on public.terms_acceptances to authenticated;
grant select, insert, delete on public.terms_acceptances to service_role;

-- The server's time, whatever the client sent.
create or replace function private.stamp_terms_acceptance()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.accepted_at := now();
  return new;
end;
$$;
revoke execute on function private.stamp_terms_acceptance() from public, anon, authenticated;
create trigger terms_acceptances_stamp before insert on public.terms_acceptances
  for each row execute function private.stamp_terms_acceptance();

-- ---------------------------------------------------------------------------
-- Minimum age
-- ---------------------------------------------------------------------------

-- docs/public/terms.md: "Pull Up is not intended for children under 13".
create or replace function private.minimum_age()
returns smallint
language sql
immutable
set search_path = ''
as $$
  select 13::smallint;
$$;
revoke execute on function private.minimum_age() from public, anon, authenticated;

create table private.age_checks (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  meets_minimum boolean not null,
  minimum_age smallint not null check (minimum_age between 13 and 21),
  -- self_declared: the person's own answer in the app, not verified.
  method text not null check (method in ('self_declared')),
  checked_at timestamptz not null default now()
);
alter table private.age_checks enable row level security;
revoke all on private.age_checks from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- The check every write runs
-- ---------------------------------------------------------------------------

-- Null when the account may publish; otherwise 'age' (no answer yet, or one
-- against a lower minimum), 'under_age', or 'terms'.
create or replace function private.consent_problem(p_user uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when a.user_id is not null and not a.meets_minimum then 'under_age'
    when a.user_id is null or a.minimum_age < private.minimum_age() then 'age'
    when not exists (
      select 1 from public.terms_acceptances t
      join public.terms_versions v on v.version = t.version and v.is_current
      where t.user_id = p_user
    ) then 'terms'
  end
  from (select 1) one
  left join private.age_checks a on a.user_id = p_user;
$$;
revoke execute on function private.consent_problem(uuid) from public, anon, authenticated;

create or replace function private.consent_message(p_problem text)
returns text
language sql
stable
set search_path = ''
as $$
  select case p_problem
    when 'under_age' then format('Pull Up is only for people %s and older, so this account can''t post, comment, message or follow.', private.minimum_age())
    when 'age' then 'Pull Up needs to confirm you meet its minimum age before you can post, comment, message or follow. Open Pull Up to continue.'
    else 'Accept Pull Up''s current Terms and Community Guidelines to post, comment, message or follow. Open Pull Up to review them.'
  end;
$$;
revoke execute on function private.consent_message(text) from public, anon, authenticated;

-- For the storage policies: answers for the caller only.
create or replace function public.my_consent_ok()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select auth.uid() is not null and private.consent_problem(auth.uid()) is null;
$$;
revoke execute on function public.my_consent_ok() from public, anon;
grant execute on function public.my_consent_ok() to authenticated, service_role;

-- Trigger arguments: how to find the row's owner ('owner' <column>, or
-- 'vehicle' / 'post' / 'drive' <column holding its id>). Only the owner's own
-- writes are checked; a moderator or another person acting on the row (a
-- followee accepting a follow, a reply updating a conversation) isn't.
create or replace function private.enforce_consent()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  rec jsonb;
  prior jsonb;
  ref uuid;
  owner uuid;
  problem text;
begin
  if me is null then
    return new;
  end if;
  rec := to_jsonb(new);
  ref := (rec ->> tg_argv[1])::uuid;
  owner := case tg_argv[0]
    when 'vehicle' then (select v.owner_id from public.vehicles v where v.id = ref)
    when 'post' then (select p.author_id from public.posts p where p.id = ref)
    when 'drive' then (select d.owner_id from public.drives d where d.id = ref)
    else ref
  end;
  if owner is distinct from me then
    return new;
  end if;
  -- An edit that publishes nothing new stays allowed: bookkeeping columns,
  -- making something less visible, cancelling a meet, unsending a message.
  if tg_op = 'UPDATE' then
    prior := to_jsonb(old);
    if not exists (
      select 1 from jsonb_each(rec) n
      where n.value is distinct from (prior -> n.key)
        and n.key not in ('updated_at', 'last_message_at', 'position', 'is_archived', 'show_me')
        -- CASE, so only a visibility value is ever cast to the enum.
        and not case n.key
          when 'visibility' then
            private.visibility_rank((n.value #>> '{}')::public.visibility)
              <= private.visibility_rank((prior ->> n.key)::public.visibility)
          when 'cancelled_at' then jsonb_typeof(prior -> n.key) = 'null' and jsonb_typeof(n.value) <> 'null'
          when 'unsent_at' then jsonb_typeof(prior -> n.key) = 'null' and jsonb_typeof(n.value) <> 'null'
          else false
        end
    ) then
      return new;
    end if;
  end if;
  problem := private.consent_problem(me);
  if problem is null then
    return new;
  end if;
  raise exception '%', private.consent_message(problem)
    using errcode = case when problem = 'terms' then 'PUC01' else 'PUC02' end,
          detail = 'consent: ' || problem;
end;
$$;
revoke execute on function private.enforce_consent() from public, anon, authenticated;

create trigger profiles_consent_required before insert or update on public.profiles
  for each row execute function private.enforce_consent('owner', 'id');
create trigger profile_details_consent_required before insert or update on public.profile_details
  for each row execute function private.enforce_consent('owner', 'user_id');
create trigger vehicles_consent_required before insert or update on public.vehicles
  for each row execute function private.enforce_consent('owner', 'owner_id');
create trigger vehicle_mods_consent_required before insert or update on public.vehicle_mods
  for each row execute function private.enforce_consent('vehicle', 'vehicle_id');
create trigger vehicle_photos_consent_required before insert or update on public.vehicle_photos
  for each row execute function private.enforce_consent('vehicle', 'vehicle_id');
create trigger posts_consent_required before insert or update on public.posts
  for each row execute function private.enforce_consent('owner', 'author_id');
create trigger post_media_consent_required before insert or update on public.post_media
  for each row execute function private.enforce_consent('post', 'post_id');
create trigger likes_consent_required before insert or update on public.likes
  for each row execute function private.enforce_consent('owner', 'user_id');
create trigger comments_consent_required before insert or update on public.comments
  for each row execute function private.enforce_consent('owner', 'author_id');
create trigger meets_consent_required before insert or update on public.meets
  for each row execute function private.enforce_consent('owner', 'host_id');
create trigger meet_rsvps_consent_required before insert or update on public.meet_rsvps
  for each row execute function private.enforce_consent('owner', 'user_id');
create trigger follows_consent_required before insert or update on public.follows
  for each row execute function private.enforce_consent('owner', 'follower_id');
create trigger conversations_consent_required before insert or update on public.conversations
  for each row execute function private.enforce_consent('owner', 'created_by');
create trigger messages_consent_required before insert or update on public.messages
  for each row execute function private.enforce_consent('owner', 'sender_id');
create trigger message_reactions_consent_required before insert or update on public.message_reactions
  for each row execute function private.enforce_consent('owner', 'user_id');
-- Insert only: changing privacy zones re-trims routes already shared, and
-- that protective update must keep working.
create trigger drive_shared_routes_consent_required before insert on public.drive_shared_routes
  for each row execute function private.enforce_consent('drive', 'drive_id');

-- No uploads or file replacements without it. Restrictive, so they add to
-- every bucket's own policies.
create policy "Storage: uploads need the age check and terms"
  on storage.objects as restrictive for insert to authenticated
  with check (public.my_consent_ok());
create policy "Storage: replacing files needs the age check and terms"
  on storage.objects as restrictive for update to authenticated
  using (true) with check (public.my_consent_ok());

-- ---------------------------------------------------------------------------
-- API
-- ---------------------------------------------------------------------------

create or replace function public.my_consent_status()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'terms_version', v.version,
    'terms_summary', coalesce(v.summary, ''),
    'terms_accepted', exists (
      select 1 from public.terms_acceptances t where t.user_id = auth.uid() and t.version = v.version),
    'accepted_version', (
      select t.version from public.terms_acceptances t where t.user_id = auth.uid()
      order by t.accepted_at desc limit 1),
    'accepted_at', (select max(t.accepted_at) from public.terms_acceptances t where t.user_id = auth.uid()),
    'minimum_age', private.minimum_age(),
    'age_check', case
      when a.user_id is null then null
      when not a.meets_minimum then 'under_minimum'
      when a.minimum_age >= private.minimum_age() then 'meets_minimum'
    end
  )
  from (select 1) one
  left join public.terms_versions v on v.is_current
  left join private.age_checks a on a.user_id = auth.uid()
  where auth.uid() is not null;
$$;
revoke execute on function public.my_consent_status() from public, anon;
grant execute on function public.my_consent_status() to authenticated, service_role;

-- Security invoker: the insert goes through the table's RLS like a direct one.
create or replace function public.accept_terms(p_version text)
returns jsonb
language plpgsql
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'sign in first' using errcode = '42501';
  end if;
  if p_version is distinct from (select v.version from public.terms_versions v where v.is_current) then
    raise exception 'Pull Up''s terms were updated. Review the latest version and accept it.' using errcode = '22023';
  end if;
  insert into public.terms_acceptances (user_id, version) values (auth.uid(), p_version)
  on conflict (user_id, version) do nothing;
  return public.my_consent_status();
end;
$$;
revoke execute on function public.accept_terms(text) from public, anon;
grant execute on function public.accept_terms(text) to authenticated;

create or replace function public.record_age_check(p_meets_minimum boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  prior private.age_checks;
begin
  if me is null then
    raise exception 'sign in first' using errcode = '42501';
  end if;
  if p_meets_minimum is null then
    raise exception 'answer the age question first' using errcode = '22023';
  end if;
  select * into prior from private.age_checks where user_id = me for update;
  if found and not prior.meets_minimum then
    if p_meets_minimum then
      raise exception 'Pull Up has already recorded that this account doesn''t meet its minimum age. Contact support if that''s wrong.'
        using errcode = 'PUC02';
    end if;
    return public.my_consent_status();
  end if;
  if found and p_meets_minimum and prior.minimum_age >= private.minimum_age() then
    return public.my_consent_status();
  end if;
  insert into private.age_checks (user_id, meets_minimum, minimum_age, method)
  values (me, p_meets_minimum, private.minimum_age(), 'self_declared')
  on conflict (user_id) do update
    set meets_minimum = excluded.meets_minimum, minimum_age = excluded.minimum_age,
        method = excluded.method, checked_at = now();
  if not p_meets_minimum then
    -- Out of sight while the account waits to be deleted.
    update public.profiles set visibility = 'private' where id = me;
    update public.privacy_settings set messages_from = 'nobody', leaderboard_opt_in = false where user_id = me;
  end if;
  return public.my_consent_status();
end;
$$;
revoke execute on function public.record_age_check(boolean) from public, anon;
grant execute on function public.record_age_check(boolean) to authenticated;
