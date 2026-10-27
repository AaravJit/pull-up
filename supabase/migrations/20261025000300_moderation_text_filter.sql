-- Moderation, part 1: a text filter enforced by the database on every
-- user-written text that other people can see (App Review guideline 1.2,
-- "a method for filtering objectionable material from being posted").
-- docs/MODERATION_RUNBOOK.md explains how to run it.
--
-- What it checks (BEFORE INSERT OR UPDATE triggers, so the REST API, the
-- RPCs and the app all go through it; an UPDATE is checked only when the
-- column changes, so adding a term never locks old rows):
--   profiles.username, profiles.display_name, profile_details.bio,
--   vehicles.make/model/trim/nickname/summary,
--   vehicle_mods.title/brand/notes, posts.caption, comments.body,
--   meets.title/details/venue_name/address, messages.body, drives.title.
-- Not checked, on purpose: privacy_zones.label (only its owner ever sees
-- it) and reports.details (read only by moderators; reporters must be able
-- to quote what they're reporting).
--
-- A blocked text fails with SQLSTATE PUM01 and a sentence the app shows as
-- is. One exception: a drive uploaded from the phone's offline queue with a
-- blocked title keeps the drive and drops the title (rejecting it would make
-- the app give up on the recording); renaming a drive is checked normally.
-- Usernames get the same answer as a reserved name ("reserved"), so the
-- existing onboarding screen explains it, and sign-up falls back to the
-- placeholder name / an empty display name instead of failing.
--
-- Matching. Both the text and each term are folded the same way: lower
-- case, Unicode compatibility decomposition with accents removed (é -> e,
-- fullwidth and styled letters -> plain), common digit/symbol swaps
-- (0->o 1->i 3->e 4->a 5->s 7->t 9->g, and inside a word @->a $->s !->i
-- |->i +->t), and
-- everything that isn't a letter becomes a space. A "word" term must match
-- whole words (so "ass" doesn't hit "class"); single letters spelled out
-- with spaces ("s p a c e d") are joined first. A "contains" term matches
-- anywhere once spaces are removed, for unambiguous strings only.
-- Repeated letters are also collapsed ("loooong") for terms of four or more
-- letters. Deliberately crafted evasion (other alphabets, images of text)
-- is not chased; reports cover it.
--
-- The term list starts EMPTY. Pull Up doesn't ship a slur list in this
-- public repository; the owner reviews and loads one (owner action, see the
-- runbook; supabase/moderation/starter_terms.sql has a minimal reviewed
-- starting set). Until then the filter blocks nothing.
--
-- There is no external filtering service: the list and the matcher live in
-- this database, in the same transaction as the write. If the list can't be
-- read the write fails (fail closed); there is nothing to time out.
--
-- Reversible: supabase/rollback/20261025000300_moderation_text_filter_down.sql.

-- ---------------------------------------------------------------------------
-- Folding and matching
-- ---------------------------------------------------------------------------

create or replace function private.moderation_fold(p text)
returns text
language sql
immutable
parallel safe
set search_path = ''
as $$
  -- Digits always count as letters; @ $ ! | + only inside a word, so
  -- "sh!t" folds to "shit" but "you idiot!" keeps its last word intact.
  select btrim(regexp_replace(
    translate(
      regexp_replace(
        regexp_replace(
          translate(regexp_replace(lower(normalize(coalesce(p, ''), NFKD)), '[\u0300-\u036f]', '', 'g'),
                    '0134579', 'oieastg'),
          '[@$!|+]+(?![a-z@$!|+])', ' ', 'g'),
        '(?<![a-z@$!|+])[@$!|+]+', ' ', 'g'),
      '@$!|+', 'asiit'),
    '[^a-z\u0370-\uffff]+', ' ', 'g'));
$$;

create or replace function private.moderation_collapse(p text)
returns text
language sql
immutable
parallel safe
set search_path = ''
as $$
  select regexp_replace(p, '([a-z])\1+', '\1', 'g');
$$;

-- Terms are stored folded (the check keeps them that way). Managed only
-- through the moderator functions (20261025000310) or by the owner in the
-- SQL editor; clients have no access at all.
create table private.moderation_terms (
  term text primary key check (term <> '' and term = private.moderation_fold(term)),
  match text not null default 'word' check (match in ('word', 'contains')),
  category text not null default 'other' check (category in ('slur', 'threat', 'sexual', 'spam', 'other')),
  note text not null default '' check (char_length(note) <= 500),
  added_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now()
);
alter table private.moderation_terms enable row level security;
revoke all on private.moderation_terms from public, anon, authenticated;

-- The first term the text contains, or null.
create or replace function private.moderation_match(p text)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  spaced text;
  joined text;
  compact text;
  spaced_c text;
  joined_c text;
  compact_c text;
  hit text;
begin
  if p is null or btrim(p) = '' or not exists (select 1 from private.moderation_terms) then
    return null;
  end if;
  spaced := private.moderation_fold(p);
  if spaced = '' then
    return null;
  end if;
  -- "s p a c e d" -> "spaced"
  joined := regexp_replace(spaced, '\m([a-z]) (?=[a-z]\M)', '\1', 'g');
  compact := replace(spaced, ' ', '');
  spaced_c := ' ' || private.moderation_collapse(spaced) || ' ';
  joined_c := ' ' || private.moderation_collapse(joined) || ' ';
  compact_c := private.moderation_collapse(compact);
  spaced := ' ' || spaced || ' ';
  joined := ' ' || joined || ' ';

  select t.term into hit
  from private.moderation_terms t
  cross join lateral (
    select private.moderation_collapse(t.term) as term_c,
           replace(t.term, ' ', '') as term_compact,
           private.moderation_collapse(replace(t.term, ' ', '')) as term_compact_c
  ) f
  where case t.match
    when 'word' then
      position(' ' || t.term || ' ' in spaced) > 0
      or position(' ' || t.term || ' ' in joined) > 0
      or (char_length(replace(f.term_c, ' ', '')) >= 4
          and (position(' ' || f.term_c || ' ' in spaced_c) > 0 or position(' ' || f.term_c || ' ' in joined_c) > 0))
    else
      position(f.term_compact in compact) > 0
      or (char_length(f.term_compact_c) >= 4 and position(f.term_compact_c in compact_c) > 0)
  end
  order by t.term
  limit 1;
  return hit;
end;
$$;

revoke execute on function private.moderation_fold(text) from public, anon, authenticated;
revoke execute on function private.moderation_collapse(text) from public, anon, authenticated;
revoke execute on function private.moderation_match(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Enforcement
-- ---------------------------------------------------------------------------

-- Trigger arguments name the columns to check. Columns are read through
-- to_jsonb, so the same function serves every table.
create or replace function private.moderation_filter_text()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  rec jsonb := to_jsonb(new);
  prev jsonb;
  col text;
  val text;
begin
  if tg_op = 'UPDATE' then
    prev := to_jsonb(old);
  end if;
  foreach col in array tg_argv loop
    val := rec ->> col;
    continue when val is null or btrim(val) = '';
    continue when tg_op = 'UPDATE' and val is not distinct from (prev ->> col);
    if private.moderation_match(val) is not null then
      raise exception 'This contains words that Pull Up''s community guidelines don''t allow. Edit it and try again.'
        using errcode = 'PUM01', detail = tg_table_name || '.' || col;
    end if;
  end loop;
  return new;
end;
$$;

-- Drives arrive from the offline upload queue, which gives up on a drive
-- the server refuses for good. A blocked title on a new drive is dropped
-- instead; a rename is refused like any other text.
create or replace function private.moderation_filter_drive_title()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.title is null or btrim(new.title) = '' then
    return new;
  end if;
  if tg_op = 'UPDATE' and new.title is not distinct from old.title then
    return new;
  end if;
  if private.moderation_match(new.title) is not null then
    if tg_op = 'INSERT' then
      new.title := '';
    else
      raise exception 'This contains words that Pull Up''s community guidelines don''t allow. Edit it and try again.'
        using errcode = 'PUM01', detail = 'drives.title';
    end if;
  end if;
  return new;
end;
$$;

revoke execute on function private.moderation_filter_text() from public, anon, authenticated;
revoke execute on function private.moderation_filter_drive_title() from public, anon, authenticated;

create trigger profiles_moderation_filter before insert or update on public.profiles
  for each row execute function private.moderation_filter_text('username', 'display_name');
create trigger profile_details_moderation_filter before insert or update on public.profile_details
  for each row execute function private.moderation_filter_text('bio');
create trigger vehicles_moderation_filter before insert or update on public.vehicles
  for each row execute function private.moderation_filter_text('make', 'model', 'trim', 'nickname', 'summary');
create trigger vehicle_mods_moderation_filter before insert or update on public.vehicle_mods
  for each row execute function private.moderation_filter_text('title', 'brand', 'notes');
create trigger posts_moderation_filter before insert or update on public.posts
  for each row execute function private.moderation_filter_text('caption');
create trigger comments_moderation_filter before insert or update on public.comments
  for each row execute function private.moderation_filter_text('body');
create trigger meets_moderation_filter before insert or update on public.meets
  for each row execute function private.moderation_filter_text('title', 'details', 'venue_name', 'address');
create trigger messages_moderation_filter before insert or update on public.messages
  for each row execute function private.moderation_filter_text('body');
create trigger drives_moderation_filter before insert or update on public.drives
  for each row execute function private.moderation_filter_drive_title();

-- ---------------------------------------------------------------------------
-- Usernames and sign-up
-- ---------------------------------------------------------------------------

-- A username containing a blocked term reads as "reserved", which the
-- onboarding screen already explains, from claim_username, username_status
-- and a direct profile update alike.
create or replace function private.username_problem(candidate text, self uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when candidate is null or candidate !~ '^[a-z0-9_.]{3,30}$' then 'format'
    when candidate ~ '^[._]|[._]$|[._]{2}' then 'format'
    when exists (
      select 1 from private.reserved_usernames r
      where candidate = r.name or (r.prefix and starts_with(candidate, r.name))
    ) then 'reserved'
    when private.moderation_match(candidate) is not null then 'reserved'
    when exists (select 1 from public.profiles p where p.username = candidate and p.id is distinct from self) then 'taken'
  end;
$$;

-- Sign-up never fails over a name: a blocked username gets the placeholder
-- (as before) and a blocked display name is left empty.
create or replace function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  requested text := lower(coalesce(new.raw_user_meta_data ->> 'username', ''));
  wanted_name text := left(coalesce(new.raw_user_meta_data ->> 'display_name', ''), 60);
  candidate text;
begin
  if private.username_problem(requested, new.id) is null then
    candidate := requested;
  else
    candidate := 'driver_' || substr(replace(new.id::text, '-', ''), 1, 10);
  end if;
  if private.moderation_match(wanted_name) is not null then
    wanted_name := '';
  end if;
  insert into public.profiles (id, username, display_name)
  values (new.id, candidate, wanted_name);
  insert into public.profile_details (user_id) values (new.id);
  insert into public.privacy_settings (user_id) values (new.id);
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Length limits that were missing (abuse control)
-- ---------------------------------------------------------------------------

-- Every other free-text column already has one. No account holds data on
-- any project yet; on one that did, an over-long row would make this fail
-- rather than be changed.
alter table public.vehicle_mods add constraint vehicle_mods_brand_length check (char_length(brand) <= 120);
alter table public.meets add constraint meets_address_length check (char_length(address) <= 300);
-- presentation is app settings (layout, accent, featured vehicle), not
-- text anyone reads; bounded so it can't be used as storage.
alter table public.profiles add constraint profiles_presentation_size check (octet_length(presentation::text) <= 2000);
