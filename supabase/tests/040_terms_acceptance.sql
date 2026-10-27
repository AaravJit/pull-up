-- Versioned terms acceptance (20261025000400): an account that hasn't
-- accepted the current Terms and Community Guidelines can't publish through
-- any API, can't fake an acceptance, and is asked again when they change.
-- Every account here passed the age check, so only the terms are in play.

begin;
create extension if not exists pgtap with schema extensions;
select plan(42);

insert into auth.users (id, email, raw_user_meta_data) values
  ('c4000000-0000-0000-0000-00000000000a', 'terms-ann@example.com', '{"username":"terms_ann"}'),
  ('c4000000-0000-0000-0000-00000000000b', 'terms-ben@example.com', '{"username":"terms_ben"}'),
  ('c4000000-0000-0000-0000-00000000000c', 'terms-cat@example.com', '{"username":"terms_cat"}');
insert into private.age_checks (user_id, meets_minimum, minimum_age, method)
select id, true, 13, 'self_declared' from public.profiles where id::text like 'c4000000-%';

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

-- An older version Cat accepted; Ben has accepted the current one; Ann
-- nothing. Ben has a public post; Ann a private car and a meet.
insert into public.terms_versions (version, summary, is_current) values ('2026-01-01', 'Earlier terms', false);
insert into public.terms_acceptances (user_id, version) values
  ('c4000000-0000-0000-0000-00000000000c', '2026-01-01'),
  ('c4000000-0000-0000-0000-00000000000b', '2026-10-27');
insert into public.posts (id, author_id, kind, caption, visibility)
values ('c4100000-0000-0000-0000-000000000001', 'c4000000-0000-0000-0000-00000000000b', 'moment', 'Ben at the meet', 'public');
insert into public.vehicles (id, owner_id, kind, make, model, year, visibility)
values ('c4200000-0000-0000-0000-000000000001', 'c4000000-0000-0000-0000-00000000000a', 'car', 'Mazda', 'RX-7', 1993, 'private');
insert into public.meets (id, host_id, title, kind, starts_at, ends_at, venue_name, lat, lon, visibility)
values ('c4300000-0000-0000-0000-000000000001', 'c4000000-0000-0000-0000-00000000000a', 'Sunday coffee', 'meet',
        now() + interval '2 days', now() + interval '2 days 3 hours', 'Cafe lot', 38.58, -121.49, 'public');

-- 1–2: the current version, and what the app sees -------------------------------
select is((select count(*)::int from public.terms_versions where is_current), 1, 'exactly one version is current');
select pg_temp.act_as('c4000000-0000-0000-0000-00000000000a');
select is(public.my_consent_status() - 'accepted_at',
  '{"terms_version": "2026-10-27", "terms_summary": "", "terms_accepted": false, "accepted_version": null, "minimum_age": 13, "age_check": "meets_minimum"}'::jsonb,
  'Ann sees that she hasn''t accepted the current terms');

-- 3–14: without acceptance nothing is published, whichever API is used ------------
select throws_ok($$ insert into public.posts (author_id, kind, caption, visibility) values (auth.uid(), 'moment', 'hi', 'public') $$,
  'PUC01', 'Accept Pull Up''s current Terms and Community Guidelines to post, comment, message or follow. Open Pull Up to review them.',
  'a post straight through REST is refused with PUC01 and the app''s sentence');
select throws_ok($$ insert into public.comments (post_id, author_id, body) values ('c4100000-0000-0000-0000-000000000001', auth.uid(), 'nice') $$,
  'PUC01', null, 'a comment is refused');
select throws_ok($$ insert into public.likes (post_id, user_id) values ('c4100000-0000-0000-0000-000000000001', auth.uid()) $$,
  'PUC01', null, 'a like is refused');
select throws_ok($$ insert into public.meets (host_id, title, kind, starts_at, ends_at, venue_name, lat, lon, visibility)
  values (auth.uid(), 'Night run', 'meet', now() + interval '1 day', now() + interval '1 day 2 hours', 'Lot', 38.5, -121.4, 'public') $$,
  'PUC01', null, 'a meet is refused');
select throws_ok($$ update public.meets set title = 'Sunday coffee and cars' where id = 'c4300000-0000-0000-0000-000000000001' $$,
  'PUC01', null, 'editing a meet''s details is refused');
select throws_ok($$ select public.start_conversation('c4000000-0000-0000-0000-00000000000b') $$,
  'PUC01', null, 'a message request through the RPC is refused');
select throws_ok($$ insert into public.follows (follower_id, followee_id) values (auth.uid(), 'c4000000-0000-0000-0000-00000000000b') $$,
  'PUC01', null, 'a follow is refused');
select throws_ok($$ update public.profile_details set bio = 'Rotary fan' where user_id = auth.uid() $$,
  'PUC01', null, 'a profile bio is refused');
select throws_ok($$ select public.claim_username('terms_ann_2', 'Ann') $$,
  'PUC01', null, 'a username and display name are refused');
select throws_ok($$ insert into public.vehicles (owner_id, kind, make, model, year) values (auth.uid(), 'car', 'Honda', 'S2000', 2004) $$,
  'PUC01', null, 'a new vehicle is refused');
select throws_ok($$ update public.vehicles set nickname = 'FD', summary = 'Single turbo' where id = 'c4200000-0000-0000-0000-000000000001' $$,
  'PUC01', null, 'a vehicle''s public fields are refused');
select throws_ok($$ insert into storage.objects (bucket_id, name) values ('avatars', 'c4000000-0000-0000-0000-00000000000a/me.jpg') $$,
  '42501', null, 'an upload is refused by the storage policy');

-- 15–18: what stays allowed ------------------------------------------------------------
select throws_ok($$ update public.vehicles set visibility = 'public' where id = 'c4200000-0000-0000-0000-000000000001' $$,
  'PUC01', null, 'making a vehicle more visible is publishing, so it is refused');
select lives_ok($$ update public.profiles set visibility = 'private' where id = auth.uid() $$,
  'making the profile less visible is allowed');
select lives_ok($$ update public.meets set cancelled_at = now() where id = 'c4300000-0000-0000-0000-000000000001' $$,
  'cancelling a meet is allowed, so attendees hear about it');
select lives_ok($$ update public.privacy_settings set messages_from = 'following' where user_id = auth.uid() $$,
  'privacy settings are allowed');

-- 19–28: the acceptance record can't be faked ------------------------------------------
select throws_ok($$ insert into public.terms_acceptances (user_id, version) values ('c4000000-0000-0000-0000-00000000000c', '2026-10-27') $$,
  '42501', null, 'bypass: Ann can''t accept on Cat''s behalf');
select throws_ok($$ insert into public.terms_acceptances (user_id, version) values (auth.uid(), '2026-01-01') $$,
  '42501', null, 'bypass: Ann can''t record acceptance of a version that isn''t current');
select throws_ok($$ select public.accept_terms('2026-01-01') $$,
  '22023', 'Pull Up''s terms were updated. Review the latest version and accept it.', 'accept_terms refuses an outdated version');
select throws_ok($$ select public.accept_terms(null) $$, '22023', null, 'and a missing one');
select throws_ok($$ update public.terms_acceptances set version = '2026-10-27' where user_id = 'c4000000-0000-0000-0000-00000000000c' $$,
  '42501', null, 'bypass: acceptances can''t be edited');
select throws_ok($$ delete from public.terms_acceptances $$, '42501', null, 'or deleted by a client');
select is((select count(*)::int from public.terms_acceptances where user_id <> auth.uid()), 0,
  'Ann can''t read anyone else''s acceptances');
select throws_ok($$ insert into public.terms_versions (version, is_current) values ('2099-01-01', false) $$,
  '42501', null, 'bypass: clients can''t publish a version of their own');
select throws_ok($$ update public.terms_versions set is_current = true where version = '2026-01-01' $$,
  '42501', null, 'or make an old version current again');
select is((select count(*)::int from public.posts where author_id = auth.uid()), 0, 'nothing of Ann''s got through');

-- 29–33: accepting (a direct insert works too, with the server's time) ------------------
select lives_ok($$ insert into public.terms_acceptances (user_id, version, accepted_at)
  values (auth.uid(), '2026-10-27', '2020-01-01') $$, 'Ann accepts the current version through REST');
select is((select accepted_at from public.terms_acceptances where user_id = auth.uid()), now(),
  'the acceptance time is the server''s, not a backdated one from the client');
select is((public.accept_terms('2026-10-27') ->> 'terms_accepted')::boolean, true, 'accept_terms again is harmless');
select lives_ok($$ insert into public.posts (author_id, kind, caption, visibility) values (auth.uid(), 'moment', 'First post', 'public') $$,
  'once accepted, Ann can post');
select lives_ok($$ insert into storage.objects (bucket_id, name) values ('avatars', 'c4000000-0000-0000-0000-00000000000a/me.jpg') $$,
  'and upload');

-- 34–36: an acceptance of an older version doesn't count -----------------------------
select pg_temp.act_as('c4000000-0000-0000-0000-00000000000c');
select is(public.my_consent_status() ->> 'accepted_version', '2026-01-01', 'Cat accepted an earlier version');
select is((public.my_consent_status() ->> 'terms_accepted')::boolean, false, 'which isn''t the current one');
select throws_ok($$ insert into public.comments (post_id, author_id, body) values ('c4100000-0000-0000-0000-000000000001', auth.uid(), 'old terms') $$,
  'PUC01', null, 'so she can''t comment until she accepts again');

-- 37–40: publishing new terms asks everyone again -------------------------------------
select pg_temp.as_admin();
update public.terms_versions set is_current = false where is_current;
insert into public.terms_versions (version, summary, is_current) values ('2026-12-01', 'Clearer rules for meets.', true);
select pg_temp.act_as('c4000000-0000-0000-0000-00000000000b');
select is(public.my_consent_status() ->> 'terms_summary', 'Clearer rules for meets.', 'Ben is told what changed');
select throws_ok($$ insert into public.posts (author_id, kind, caption, visibility) values (auth.uid(), 'moment', 'still ok?', 'public') $$,
  'PUC01', null, 'and can''t post until he accepts the new version');
select lives_ok($$ select public.accept_terms('2026-12-01') $$, 'Ben accepts it');
select lives_ok($$ insert into public.posts (author_id, kind, caption, visibility) values (auth.uid(), 'moment', 'back', 'public') $$,
  'and posts again');

-- 41–42: the server itself, and signed-out callers ----------------------------------
select pg_temp.as_admin();
select lives_ok($$ insert into public.posts (author_id, kind, caption, visibility)
  values ('c4000000-0000-0000-0000-00000000000c', 'moment', 'imported by the server', 'private') $$,
  'the server (no signed-in user) isn''t affected');
select pg_temp.as_anon();
select throws_ok($$ select public.accept_terms('2026-12-01') $$, '42501', null, 'signed-out callers can''t accept anything');

select * from finish();
rollback;
