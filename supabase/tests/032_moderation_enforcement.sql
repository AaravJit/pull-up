-- Enforcement (20261025000310): removed content disappears from every read
-- path while the evidence stays, its media is queued for deletion, three
-- independent reports hide an item pending review, and a suspended account
-- can't write through any table, RPC or upload.

begin;
create extension if not exists pgtap with schema extensions;
select plan(50);

insert into auth.users (id, email, raw_user_meta_data) values
  ('f3200000-0000-0000-0000-00000000000a'::uuid, 'me-ann@example.com', '{"username":"me_ann"}'),
  ('f3200000-0000-0000-0000-00000000000b'::uuid, 'me-ben@example.com', '{"username":"me_ben"}'),
  ('f3200000-0000-0000-0000-00000000000c'::uuid, 'me-cat@example.com', '{"username":"me_cat"}'),
  ('f3200000-0000-0000-0000-00000000000d'::uuid, 'me-dan@example.com', '{"username":"me_dan"}'),
  ('f3200000-0000-0000-0000-00000000000e'::uuid, 'me-eve@example.com', '{"username":"me_eve"}');
-- These accounts confirmed the minimum age and accepted the current terms
-- (20261025000400); 040/041 test what happens without that.
insert into public.terms_acceptances (user_id, version)
select p.id, v.version from public.profiles p, public.terms_versions v where v.is_current on conflict do nothing;
insert into private.age_checks (user_id, meets_minimum, minimum_age, method)
select id, true, 13, 'self_declared' from public.profiles on conflict do nothing;
-- Reporters' accounts are older than a day (only those count towards auto-hiding).
update public.profiles set created_at = now() - interval '30 days' where id::text like 'f3200000-%';

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

-- Ann (author) and Ben follow each other.
insert into public.follows (follower_id, followee_id) values
  ('f3200000-0000-0000-0000-00000000000a', 'f3200000-0000-0000-0000-00000000000b'),
  ('f3200000-0000-0000-0000-00000000000b', 'f3200000-0000-0000-0000-00000000000a');
insert into public.vehicles (id, owner_id, kind, make, model, year, visibility, cover_photo_path) values
  ('f3210000-0000-0000-0000-000000000001', 'f3200000-0000-0000-0000-00000000000a', 'car', 'Nissan', 'S13', 1991, 'public',
   'f3200000-0000-0000-0000-00000000000a/cover.jpg');
insert into public.vehicle_photos (vehicle_id, storage_path) values
  ('f3210000-0000-0000-0000-000000000001', 'f3200000-0000-0000-0000-00000000000a/s13-1.jpg');
insert into public.posts (id, author_id, caption, visibility) values
  ('f3220000-0000-0000-0000-000000000001', 'f3200000-0000-0000-0000-00000000000a', 'Bad post', 'public'),
  ('f3220000-0000-0000-0000-000000000002', 'f3200000-0000-0000-0000-00000000000a', 'Brigaded post', 'public');
insert into public.post_media (post_id, storage_path, media_type) values
  ('f3220000-0000-0000-0000-000000000001', 'f3200000-0000-0000-0000-00000000000a/p1/v.mp4', 'video');
insert into storage.objects (bucket_id, name) values
  ('post-media', 'f3200000-0000-0000-0000-00000000000a/p1/v.mp4');
insert into public.comments (id, post_id, author_id, body) values
  ('f3230000-0000-0000-0000-000000000001', 'f3220000-0000-0000-0000-000000000002', 'f3200000-0000-0000-0000-00000000000a', 'Bad comment');
insert into public.meets (id, host_id, title, starts_at, ends_at, venue_name, lat, lon) values
  ('f3240000-0000-0000-0000-000000000001', 'f3200000-0000-0000-0000-00000000000a', 'Bad meet',
   now() + interval '1 day', now() + interval '1 day 2 hours', 'Lot', 1, 1);

-- Ben reports the post; it is visible before removal.
select pg_temp.act_as('f3200000-0000-0000-0000-00000000000b');
create temp table rep on commit drop as
  select public.report_content('post', 'f3220000-0000-0000-0000-000000000001', 'sexual', 'explicit video') as id;
select is((select count(*)::int from public.post_media where post_id = 'f3220000-0000-0000-0000-000000000001'), 1, 'Ben sees the post''s video before removal');
select ok(exists (select 1 from storage.objects where name = 'f3200000-0000-0000-0000-00000000000a/p1/v.mp4'), 'and can fetch the file');

-- The owner (server) removes it, the vehicle, the comment and the meet.
select pg_temp.as_admin();
select public.mod_set_content_state('post', 'f3220000-0000-0000-0000-000000000001', 'removed', (select id from rep), 'explicit');
select public.mod_set_content_state('vehicle', 'f3210000-0000-0000-0000-000000000001', 'removed');
select public.mod_set_content_state('comment', 'f3230000-0000-0000-0000-000000000001', 'removed');
select public.mod_set_content_state('meet', 'f3240000-0000-0000-0000-000000000001', 'removed');

select pg_temp.act_as('f3200000-0000-0000-0000-00000000000b');
select is((select count(*)::int from public.posts where id = 'f3220000-0000-0000-0000-000000000001'), 0, 'a removed post is gone for others');
select is((select count(*)::int from public.home_feed() where id = 'f3220000-0000-0000-0000-000000000001'), 0, 'and from the feed');
select is((select count(*)::int from public.post_media where post_id = 'f3220000-0000-0000-0000-000000000001'), 0, 'and its media rows');
select ok(not exists (select 1 from storage.objects where name = 'f3200000-0000-0000-0000-00000000000a/p1/v.mp4'), 'and its file in Storage');
select is(public.shared_preview('post', 'f3220000-0000-0000-0000-000000000001') ->> 'available', 'false', 'and its shared card');
select is((select count(*)::int from public.vehicles where id = 'f3210000-0000-0000-0000-000000000001'), 0, 'a removed vehicle is gone');
select is((select count(*)::int from public.vehicle_photos where vehicle_id = 'f3210000-0000-0000-0000-000000000001'), 0, 'with its photos');
select is((select count(*)::int from public.comments where id = 'f3230000-0000-0000-0000-000000000001'), 0, 'a removed comment is gone');
select is((select public.comment_count(p) from public.posts p where p.id = 'f3220000-0000-0000-0000-000000000002'), 0, 'and not counted');
select is((select count(*)::int from public.meets where id = 'f3240000-0000-0000-0000-000000000001'), 0, 'a removed meet is gone');
select throws_ok($$ select public.report_content('post', 'f3220000-0000-0000-0000-000000000001', 'spam') $$, '42501', null, 'removed content can''t be reported again');

select pg_temp.act_as('f3200000-0000-0000-0000-00000000000a');
select is((select count(*)::int from public.posts where id = 'f3220000-0000-0000-0000-000000000001'), 0, 'removed content is hidden from its author too');
update public.posts set moderation_state = null where id = 'f3220000-0000-0000-0000-000000000001';
select lives_ok($$ insert into public.posts (author_id, caption) values (auth.uid(), 'sneaky') $$, 'a client insert works');
select is((select moderation_state from public.posts where caption = 'sneaky'), null, 'and can''t set its own moderation state');

select pg_temp.as_admin();
select is((select snapshot ->> 'caption' from public.reports where id = (select id from rep)), 'Bad post', 'the evidence stays with the report');
select is((select caption from public.posts where id = 'f3220000-0000-0000-0000-000000000001'), 'Bad post', 'and the row is kept, hidden');
select is((select moderation_state from public.posts where id = 'f3220000-0000-0000-0000-000000000001'), 'removed', 'the author couldn''t un-remove it');
select is((select count(*)::int from private.moderation_media_purge where content_id = 'f3220000-0000-0000-0000-000000000001' and remove_after > now() + interval '29 days'), 1,
          'the video is queued for deletion after the evidence hold');
select is((select count(*)::int from private.moderation_media_purge where content_id = 'f3210000-0000-0000-0000-000000000001'), 2, 'and the vehicle''s photos and cover');
select set_config('role', 'service_role', true);
select is((select count(*)::int from public.moderation_due_media()), 0, 'nothing is due before the hold ends');
select pg_temp.as_admin();
update private.moderation_media_purge set remove_after = now() - interval '1 second';
select set_config('role', 'service_role', true);
select is((select count(*)::int from public.moderation_due_media()), 3, 'then the worker gets each file');
select public.moderation_media_removed('post-media', array['f3200000-0000-0000-0000-00000000000a/p1/v.mp4']);
select is((select count(*)::int from public.moderation_due_media()), 2, 'and records the deletion');
select pg_temp.as_admin();

-- Restoring brings the vehicle back and cancels pending deletions.
select public.mod_set_content_state('vehicle', 'f3210000-0000-0000-0000-000000000001', 'visible');
select is((select count(*)::int from private.moderation_media_purge where content_id = 'f3210000-0000-0000-0000-000000000001'), 0, 'restoring cancels the media deletion');
select pg_temp.act_as('f3200000-0000-0000-0000-00000000000b');
select is((select count(*)::int from public.vehicles where id = 'f3210000-0000-0000-0000-000000000001'), 1, 'and the vehicle is visible again');

-- Three different established accounts reporting the same post hide it pending review.
select pg_temp.act_as('f3200000-0000-0000-0000-00000000000c');
select public.report_content('post', 'f3220000-0000-0000-0000-000000000002', 'hate');
select pg_temp.act_as('f3200000-0000-0000-0000-00000000000d');
select public.report_content('post', 'f3220000-0000-0000-0000-000000000002', 'hate');
select is((select count(*)::int from public.posts where id = 'f3220000-0000-0000-0000-000000000002'), 1, 'two reports don''t hide anything');
select pg_temp.act_as('f3200000-0000-0000-0000-00000000000e');
select public.report_content('post', 'f3220000-0000-0000-0000-000000000002', 'hate');
select is((select count(*)::int from public.posts where id = 'f3220000-0000-0000-0000-000000000002'), 0, 'the third hides it from others');
select pg_temp.act_as('f3200000-0000-0000-0000-00000000000a');
select is((select count(*)::int from public.posts where id = 'f3220000-0000-0000-0000-000000000002'), 1, 'while its author still sees it');
select pg_temp.as_admin();
select is((select count(*)::int from public.reports where content_id = 'f3220000-0000-0000-0000-000000000002' and priority = 'urgent'), 3, 'and its reports become urgent');
select is((select actor_kind || ':' || action from private.moderation_audit where content_id = 'f3220000-0000-0000-0000-000000000002'), 'automatic:auto_hide', 'automatic hiding is audited');

-- Suspension: every write path refuses Ann, reading and leaving still work.
select public.mod_suspend_user('f3200000-0000-0000-0000-00000000000a', now() + interval '7 days', 'Threats in a post');
create temp table conv on commit drop as select 'x'::text as k;
select pg_temp.act_as('f3200000-0000-0000-0000-00000000000a');
select is(public.my_moderation_status() ->> 'suspended', 'true', 'Ann can see that she is suspended');
select is(public.my_moderation_status() ->> 'reason', 'Threats in a post', 'and why');
select throws_ok($$ insert into public.posts (author_id, caption) values (auth.uid(), 'hi') $$, 'PUM02', null, 'no posts');
select throws_ok($$ insert into public.comments (post_id, author_id, body) values ('f3220000-0000-0000-0000-000000000002', auth.uid(), 'hi') $$, 'PUM02', null, 'no comments');
select throws_ok($$ insert into public.likes (post_id, user_id) values ('f3220000-0000-0000-0000-000000000002', auth.uid()) $$, 'PUM02', null, 'no likes');
select throws_ok($$ select public.start_conversation('f3200000-0000-0000-0000-00000000000c') $$, 'PUM02', null, 'no new conversations');
select throws_ok($$ insert into public.follows (follower_id, followee_id) values (auth.uid(), 'f3200000-0000-0000-0000-00000000000c') $$, 'PUM02', null, 'no follows');
select throws_ok($$ insert into public.meets (host_id, title, starts_at, ends_at, venue_name, lat, lon) values (auth.uid(), 'New meet', now() + interval '2 days', now() + interval '2 days 1 hour', 'Lot', 1, 1) $$, 'PUM02', null, 'no meets');
select throws_ok($$ update public.vehicles set nickname = 'x' where id = 'f3210000-0000-0000-0000-000000000001' $$, 'PUM02', null, 'no garage edits');
select throws_ok($$ insert into public.vehicle_photos (vehicle_id, storage_path) values ('f3210000-0000-0000-0000-000000000001', auth.uid() || '/new.jpg') $$, 'PUM02', null, 'no vehicle photos');
select throws_ok($$ update public.profile_details set bio = 'x' where user_id = auth.uid() $$, 'PUM02', null, 'no bio edits');
select throws_ok($$ select public.claim_username('me_ann_new', 'Ann') $$, 'PUM02', null, 'no renaming through RPCs either');
select throws_ok($$ insert into storage.objects (bucket_id, name) values ('avatars', auth.uid() || '/a.jpg') $$, '42501', null, 'no uploads');
select lives_ok($$ delete from public.posts where caption = 'sneaky' $$, 'she can still delete her own content');
select lives_ok($$ update public.profiles set visibility = 'private' where id = auth.uid() $$, 'and change who can see her profile');
select lives_ok($$ insert into public.blocks (blocker_id, blocked_id) values (auth.uid(), 'f3200000-0000-0000-0000-00000000000e') $$, 'block');
select lives_ok($$ select public.report_content('profile', 'f3200000-0000-0000-0000-00000000000c', 'spam') $$, 'and report');

-- Lifting it restores writing; it is audited.
select pg_temp.as_admin();
select public.mod_unsuspend_user('f3200000-0000-0000-0000-00000000000a', 'served');
select pg_temp.act_as('f3200000-0000-0000-0000-00000000000a');
select lives_ok($$ insert into public.posts (author_id, caption) values (auth.uid(), 'back') $$, 'after the suspension is lifted she can post');
select pg_temp.as_admin();
select is((select array_agg(action order by id) from private.moderation_audit where subject_id = 'f3200000-0000-0000-0000-00000000000a' and action like 'account_%'),
          array['account_suspended', 'account_unsuspended'], 'suspension and lifting are audited');

select * from finish();
rollback;
