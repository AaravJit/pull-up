-- Minimum age (20261025000400): no publishing or social actions until the
-- account has a passing age check, which a client can only record through
-- record_age_check, can't change once it failed, and never includes a birth
-- date. Every account here accepted the current terms, so only age is in play.

begin;
create extension if not exists pgtap with schema extensions;
select plan(27);

insert into auth.users (id, email, raw_user_meta_data) values
  ('c5000000-0000-0000-0000-00000000000a', 'age-ann@example.com', '{"username":"age_ann"}'),
  ('c5000000-0000-0000-0000-00000000000b', 'age-ben@example.com', '{"username":"age_ben"}'),
  ('c5000000-0000-0000-0000-00000000000c', 'age-kid@example.com', '{"username":"age_kid"}');
insert into public.terms_acceptances (user_id, version)
select p.id, v.version from public.profiles p, public.terms_versions v where v.is_current and p.id::text like 'c5000000-%';
insert into private.age_checks (user_id, meets_minimum, minimum_age, method)
values ('c5000000-0000-0000-0000-00000000000b', true, 13, 'self_declared');
update public.profiles set visibility = 'public' where id::text like 'c5000000-%';
update public.privacy_settings set messages_from = 'everyone', leaderboard_opt_in = true where user_id::text like 'c5000000-%';
insert into public.posts (id, author_id, kind, caption, visibility)
values ('c5100000-0000-0000-0000-000000000001', 'c5000000-0000-0000-0000-00000000000b', 'moment', 'Ben''s car', 'public');

create or replace function pg_temp.act_as(uid uuid) returns void language plpgsql as $$
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', uid::text, true);
end $$;

create or replace function pg_temp.as_admin() returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
end $$;

create or replace function pg_temp.as_anon() returns void language plpgsql as $$
begin
  perform set_config('role', 'anon', true);
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  perform set_config('request.jwt.claim.sub', '', true);
end $$;

-- 1–7: no answer yet ---------------------------------------------------------------------
select pg_temp.act_as('c5000000-0000-0000-0000-00000000000a');
select is(public.my_consent_status() -> 'age_check', 'null'::jsonb, 'Ann hasn''t answered the age question');
select throws_ok($$ insert into public.posts (author_id, kind, caption, visibility) values (auth.uid(), 'moment', 'hi', 'public') $$,
  'PUC02', 'Pull Up needs to confirm you meet its minimum age before you can post, comment, message or follow. Open Pull Up to continue.',
  'a post is refused with PUC02 even with the terms accepted');
select throws_ok($$ insert into public.follows (follower_id, followee_id) values (auth.uid(), 'c5000000-0000-0000-0000-00000000000b') $$,
  'PUC02', null, 'a follow is refused');
select throws_ok($$ select public.start_conversation('c5000000-0000-0000-0000-00000000000b') $$,
  'PUC02', null, 'a message request is refused');
select throws_ok($$ insert into public.likes (post_id, user_id) values ('c5100000-0000-0000-0000-000000000001', auth.uid()) $$,
  'PUC02', null, 'a like is refused');
select throws_ok($$ insert into private.age_checks (user_id, meets_minimum, minimum_age, method) values (auth.uid(), true, 13, 'self_declared') $$,
  '42501', null, 'bypass: the outcome can''t be written directly');
select throws_ok($$ select meets_minimum from private.age_checks $$, '42501', null, 'or read directly');

-- 8–11: a passing answer ------------------------------------------------------------------
select throws_ok($$ select public.record_age_check(null) $$, '22023', null, 'an empty answer is refused');
select is(public.record_age_check(true) ->> 'age_check', 'meets_minimum', 'Ann confirms she meets the minimum');
select lives_ok($$ insert into public.posts (author_id, kind, caption, visibility) values (auth.uid(), 'moment', 'hi', 'public') $$,
  'and can post');
select is(public.record_age_check(true) ->> 'age_check', 'meets_minimum', 'answering again changes nothing');

-- 12–23: an answer under the minimum ---------------------------------------------------
select pg_temp.act_as('c5000000-0000-0000-0000-00000000000c');
select is(public.record_age_check(false) ->> 'age_check', 'under_minimum', 'Kid answers that they''re under the minimum');
select throws_ok($$ insert into public.posts (author_id, kind, caption, visibility) values (auth.uid(), 'moment', 'hi', 'public') $$,
  'PUC02', 'Pull Up is only for people 13 and older, so this account can''t post, comment, message or follow.',
  'Kid can''t post, and is told why');
select throws_ok($$ insert into public.comments (post_id, author_id, body) values ('c5100000-0000-0000-0000-000000000001', auth.uid(), 'hi') $$,
  'PUC02', null, 'or comment');
select throws_ok($$ select public.start_conversation('c5000000-0000-0000-0000-00000000000b') $$,
  'PUC02', null, 'or start a conversation');
select throws_ok($$ select public.record_age_check(true) $$, 'PUC02', null,
  'bypass: answering again with a passing answer doesn''t change the record');
select throws_ok($$ update public.profiles set visibility = 'public' where id = auth.uid() $$,
  'PUC02', null, 'bypass: Kid can''t make the profile public again');
select lives_ok($$ delete from public.likes where user_id = auth.uid() $$, 'Kid can still remove things');
select pg_temp.as_admin();
select is((select visibility::text from public.profiles where id = 'c5000000-0000-0000-0000-00000000000c'), 'private',
  'the profile was made private');
select is((select messages_from || '/' || leaderboard_opt_in from public.privacy_settings where user_id = 'c5000000-0000-0000-0000-00000000000c'),
  'nobody/false', 'messages from anyone are off and the account left the leaderboards');
select is((select meets_minimum from private.age_checks where user_id = 'c5000000-0000-0000-0000-00000000000c'), false,
  'the failing answer is still the record');
select pg_temp.act_as('c5000000-0000-0000-0000-00000000000b');
select throws_ok($$ select public.start_conversation('c5000000-0000-0000-0000-00000000000c') $$,
  '42501', null, 'other people can''t message the account');
select pg_temp.act_as('c5000000-0000-0000-0000-00000000000a');
select is(public.record_age_check(false) ->> 'age_check', 'under_minimum', 'a passing answer can still be lowered');

-- 24–27: what is kept, and who can ask -------------------------------------------------
select pg_temp.as_admin();
select is((select array_agg(column_name::text order by ordinal_position) from information_schema.columns
           where table_schema = 'private' and table_name = 'age_checks'),
  array['user_id', 'meets_minimum', 'minimum_age', 'method', 'checked_at'],
  'only the outcome is kept: no birth date or age');
select is((select count(*)::int from pg_trigger where tgname like '%\_consent\_required' and not tgisinternal), 16,
  'the consent triggers have their own names (moderation''s are _active_account and _moderation_filter)');
select pg_temp.as_anon();
select throws_ok($$ select public.record_age_check(true) $$, '42501', null, 'signed-out callers can''t record an answer');
select throws_ok($$ select public.my_consent_status() $$, '42501', null, 'or read a status');

select * from finish();
rollback;
