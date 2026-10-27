-- Posts with media appear complete or not at all (20261025000200):
-- publish_post checks every file is in storage and writes the post and its
-- media together, the same id twice makes one post, media can't be attached
-- any other way, and files no post uses are listed for cleanup.

begin;
create extension if not exists pgtap with schema extensions;
select plan(44);

insert into auth.users (id, email, raw_user_meta_data) values
  ('b7000000-0000-0000-0000-00000000000a', 'publish-ann@example.com', '{"username":"publish_ann"}'),
  ('b7000000-0000-0000-0000-00000000000b', 'publish-ben@example.com', '{"username":"publish_ben"}'),
  ('b7000000-0000-0000-0000-00000000000c', 'publish-cat@example.com', '{"username":"publish_cat"}');

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

create or replace function pg_temp.as_service() returns void language plpgsql as $$
begin
  perform set_config('role', 'service_role', true);
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  perform set_config('request.jwt.claim.sub', '', true);
end $$;

-- Ann's draft: post b7100000-...01 with two photos, "<ann>/<post>/one.jpg" and "two.jpg".
create or replace function pg_temp.media(variadic names text[]) returns jsonb language sql as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'path', 'b7000000-0000-0000-0000-00000000000a/b7100000-0000-0000-0000-000000000001/' || n,
    'type', 'image', 'width', 1080, 'height', 1350) order by o), '[]'::jsonb)
  from unnest(names) with ordinality as u(n, o);
$$;
grant execute on function pg_temp.media(text[]) to authenticated, service_role;

create or replace function pg_temp.post_count() returns int language sql as $$
  select count(*)::int from public.posts where id = 'b7100000-0000-0000-0000-000000000001';
$$;
create or replace function pg_temp.media_count() returns int language sql as $$
  select count(*)::int from public.post_media where post_id = 'b7100000-0000-0000-0000-000000000001';
$$;
grant execute on function pg_temp.post_count() to authenticated, service_role;
grant execute on function pg_temp.media_count() to authenticated, service_role;

select pg_temp.act_as('b7000000-0000-0000-0000-00000000000b');
insert into public.follows (follower_id, followee_id) values (auth.uid(), 'b7000000-0000-0000-0000-00000000000a');

-- 1–3: who may call it ------------------------------------------------------------
select pg_temp.as_admin();
set local role anon;
select throws_ok($$ select public.publish_post('b7100000-0000-0000-0000-000000000001') $$,
  '42501', null, 'signed-out callers can''t publish');
reset role;
select pg_temp.act_as('b7000000-0000-0000-0000-00000000000a');
select set_config('request.jwt.claims', '{"role":"authenticated"}', true), set_config('request.jwt.claim.sub', '', true);
select throws_ok($$ select public.publish_post('b7100000-0000-0000-0000-000000000001') $$,
  '42501', null, 'a token without a user can''t publish');
select pg_temp.act_as('b7000000-0000-0000-0000-00000000000a');
select throws_ok($$ select public.publish_post(null) $$, '22023', null, 'a post needs its client-made id');

-- 4–9: an upload that didn't finish leaves no post ---------------------------------
insert into storage.objects (bucket_id, name, metadata)
values ('post-media', 'b7000000-0000-0000-0000-00000000000a/b7100000-0000-0000-0000-000000000001/one.jpg',
        '{"mimetype":"image/jpeg","size":1000}');
select throws_ok($$ select public.publish_post('b7100000-0000-0000-0000-000000000001', 'moment', 'Two photos', 'public',
                                               p_media => pg_temp.media('one.jpg', 'two.jpg')) $$,
  'P0002', null, 'publishing while the second photo is missing is refused');
select is(pg_temp.post_count(), 0, 'the author sees no half post');
select is(pg_temp.media_count(), 0, 'and no media rows');
select pg_temp.act_as('b7000000-0000-0000-0000-00000000000b');
select is(pg_temp.post_count(), 0, 'a follower sees no post');
select is((select count(*)::int from public.home_feed() where id = 'b7100000-0000-0000-0000-000000000001'), 0,
  'nothing in the follower''s home feed');
select is((select count(*)::int from storage.objects where bucket_id = 'post-media' and name like 'b7000000-0000-0000-0000-00000000000a/%'), 0,
  'a follower can''t open the draft''s uploaded photo');

-- 10–16: once every file is there, the post and all its media appear together ------
select pg_temp.act_as('b7000000-0000-0000-0000-00000000000a');
insert into storage.objects (bucket_id, name, metadata)
values ('post-media', 'b7000000-0000-0000-0000-00000000000a/b7100000-0000-0000-0000-000000000001/two.jpg',
        '{"mimetype":"image/jpeg","size":1000}');
select is(public.publish_post('b7100000-0000-0000-0000-000000000001', 'moment', 'Two photos', 'public',
                              p_media => pg_temp.media('one.jpg', 'two.jpg')),
  'b7100000-0000-0000-0000-000000000001'::uuid, 'publishing returns the post id');
select is(pg_temp.media_count(), 2, 'both photos are attached');
select is((select array_agg(storage_path order by position) from public.post_media where post_id = 'b7100000-0000-0000-0000-000000000001'),
  array['b7000000-0000-0000-0000-00000000000a/b7100000-0000-0000-0000-000000000001/one.jpg',
        'b7000000-0000-0000-0000-00000000000a/b7100000-0000-0000-0000-000000000001/two.jpg'],
  'in the order they were picked');
select pg_temp.act_as('b7000000-0000-0000-0000-00000000000b');
select is(pg_temp.post_count(), 1, 'the follower now sees the post');
select is(pg_temp.media_count(), 2, 'with both photos');
select is((select count(*)::int from public.home_feed() where id = 'b7100000-0000-0000-0000-000000000001'), 1,
  'and it is in the home feed');
select is((select count(*)::int from storage.objects where bucket_id = 'post-media' and name like 'b7000000-0000-0000-0000-00000000000a/%'), 2,
  'and can open both files');

-- 17–21: the same id again is the same post -----------------------------------------
select pg_temp.act_as('b7000000-0000-0000-0000-00000000000a');
select is(public.publish_post('b7100000-0000-0000-0000-000000000001', 'moment', 'Two photos', 'public',
                              p_media => pg_temp.media('one.jpg', 'two.jpg')),
  'b7100000-0000-0000-0000-000000000001'::uuid, 'a retry after a lost response returns the same post');
select is(public.publish_post('b7100000-0000-0000-0000-000000000001', 'moment', 'Edited before retrying', 'public',
                              p_media => pg_temp.media('one.jpg')),
  'b7100000-0000-0000-0000-000000000001'::uuid, 'a retry with changed fields also returns it');
select is(pg_temp.post_count(), 1, 'still one post');
select is(pg_temp.media_count(), 2, 'still two photos');
select is((select caption from public.posts where id = 'b7100000-0000-0000-0000-000000000001'), 'Two photos',
  'the first publish wins');

-- 22–25: interrupted uploads: re-sending a file, and the relaunch check ------------
-- The app re-sends a file whose upload timed out (Storage upserts the same
-- object), then publishes: still one media row per file.
insert into storage.objects (bucket_id, name, metadata)
values ('post-media', 'b7000000-0000-0000-0000-00000000000a/b7100000-0000-0000-0000-000000000007/again.jpg', '{"mimetype":"image/jpeg"}');
update storage.objects set metadata = '{"mimetype":"image/jpeg","size":2}'
where name = 'b7000000-0000-0000-0000-00000000000a/b7100000-0000-0000-0000-000000000007/again.jpg';
select is(public.publish_post('b7100000-0000-0000-0000-000000000007', p_media => jsonb_build_array(jsonb_build_object(
            'path', 'b7000000-0000-0000-0000-00000000000a/b7100000-0000-0000-0000-000000000007/again.jpg',
            'type', 'image', 'width', 10, 'height', 10))),
  'b7100000-0000-0000-0000-000000000007'::uuid, 'a file sent twice publishes');
select is((select count(*)::int from public.post_media where post_id = 'b7100000-0000-0000-0000-000000000007'), 1,
  'with one media row');
-- After a relaunch the app asks whether each unfinished draft was published
-- (keep its files) or not (delete them); the author can tell which.
select is((select count(*)::int from public.posts where id = 'b7100000-0000-0000-0000-000000000007'), 1,
  'a draft that published before the app closed is found');
select is((select count(*)::int from public.posts where id = 'b7100000-0000-0000-0000-000000000009'), 0,
  'one that never published isn''t');

-- 26–33: what a direct API caller can't do ------------------------------------------
select pg_temp.act_as('b7000000-0000-0000-0000-00000000000b');
select throws_ok($$ select public.publish_post('b7100000-0000-0000-0000-000000000001', 'moment', 'mine now') $$,
  '42501', null, 'someone else''s post id can''t be reused');
select throws_ok($$ select public.publish_post('b7100000-0000-0000-0000-000000000002', 'moment', 'stolen photo', 'public',
                                               p_media => jsonb_build_array(jsonb_build_object(
                                                 'path', 'b7000000-0000-0000-0000-00000000000a/b7100000-0000-0000-0000-000000000001/one.jpg',
                                                 'type', 'image', 'width', 10, 'height', 10))) $$,
  '22023', null, 'someone else''s file can''t be attached');
select is((select count(*)::int from public.posts where id = 'b7100000-0000-0000-0000-000000000002'), 0, 'and no post was made');
select pg_temp.act_as('b7000000-0000-0000-0000-00000000000a');
select throws_ok($$ select public.publish_post('b7100000-0000-0000-0000-000000000003', 'moment', 'reused file', 'public',
                                               p_media => pg_temp.media('one.jpg')) $$,
  '22023', null, 'a file from another post''s folder can''t be attached');
select throws_ok($$ insert into public.post_media (post_id, storage_path, media_type)
                   values ('b7100000-0000-0000-0000-000000000001',
                           'b7000000-0000-0000-0000-00000000000a/b7100000-0000-0000-0000-000000000001/missing.jpg', 'image') $$,
  '42501', null, 'media rows can''t be inserted directly, even on your own post');
select throws_ok($$ update public.post_media set storage_path = storage_path || 'x'
                   where post_id = 'b7100000-0000-0000-0000-000000000001' $$,
  '42501', null, 'or repointed');
insert into storage.objects (bucket_id, name, metadata)
values ('post-media', 'b7000000-0000-0000-0000-00000000000a/b7100000-0000-0000-0000-000000000004/clip.mp4',
        '{"mimetype":"video/mp4","size":1000}');
select throws_ok($$ select public.publish_post('b7100000-0000-0000-0000-000000000004', 'moment', 'not a photo', 'public',
                                               p_media => jsonb_build_array(jsonb_build_object(
                                                 'path', 'b7000000-0000-0000-0000-00000000000a/b7100000-0000-0000-0000-000000000004/clip.mp4',
                                                 'type', 'image', 'width', 10, 'height', 10))) $$,
  '22023', null, 'a video can''t be published as a photo');
select throws_ok($$ select public.publish_post('b7100000-0000-0000-0000-000000000004', 'moment', 'too many', 'public',
                                               p_media => (select jsonb_agg(jsonb_build_object('path', 'x', 'type', 'image'))
                                                           from generate_series(1, 11))) $$,
  '22023', null, 'at most 10 media items');

-- 34–37: other posts still work, and the existing guards still apply --------------
select is(public.publish_post('b7100000-0000-0000-0000-000000000004', 'moment', 'A clip', 'friends',
                              p_media => jsonb_build_array(jsonb_build_object(
                                'path', 'b7000000-0000-0000-0000-00000000000a/b7100000-0000-0000-0000-000000000004/clip.mp4',
                                'type', 'video', 'width', 1080, 'height', 1920, 'duration_s', 12.5))),
  'b7100000-0000-0000-0000-000000000004'::uuid, 'a video publishes');
select is(public.publish_post('b7100000-0000-0000-0000-000000000005', p_caption => 'Just words'),
  'b7100000-0000-0000-0000-000000000005'::uuid, 'a text-only post publishes');
select lives_ok($$ insert into public.posts (author_id, caption) values (auth.uid(), 'direct text post') $$,
  'text-only posts can still be inserted directly');
insert into public.vehicles (id, owner_id, kind, make, model, year, visibility)
values ('b7200000-0000-0000-0000-000000000001', auth.uid(), 'car', 'Mazda', 'MX-5', 1990, 'private');
select throws_ok($$ select public.publish_post('b7100000-0000-0000-0000-000000000006', 'build', 'Hidden car', 'public',
                                               'b7200000-0000-0000-0000-000000000001') $$,
  '42501', null, 'a post still can''t be more visible than its vehicle');

-- 38–44: cleanup of files no post uses ----------------------------------------------
select pg_temp.as_admin();
insert into storage.objects (bucket_id, name, metadata, created_at) values
  ('post-media', 'b7000000-0000-0000-0000-00000000000a/b7100000-0000-0000-0000-000000000009/abandoned.jpg', '{"mimetype":"image/jpeg"}', now() - interval '2 days'),
  ('post-media', 'b7000000-0000-0000-0000-00000000000a/b7100000-0000-0000-0000-000000000009/fresh.jpg', '{"mimetype":"image/jpeg"}', now() - interval '1 hour'),
  ('post-media', 'b7000000-0000-0000-0000-00000000000c/b7100000-0000-0000-0000-000000000008/reported.jpg', '{"mimetype":"image/jpeg"}', now() - interval '2 days');
update storage.objects set created_at = now() - interval '2 days'
where bucket_id = 'post-media' and name like 'b7000000-0000-0000-0000-00000000000a/b7100000-0000-0000-0000-000000000001/%';
insert into public.reports (reporter_id, subject_id, reason, snapshot)
values ('b7000000-0000-0000-0000-00000000000a', 'b7000000-0000-0000-0000-00000000000c', 'spam',
        '{"content_kind":"post","media":["b7000000-0000-0000-0000-00000000000c/b7100000-0000-0000-0000-000000000008/reported.jpg"]}');

select pg_temp.act_as('b7000000-0000-0000-0000-00000000000a');
select throws_ok($$ select * from public.post_orphaned_media() $$, '42501', null, 'signed-in users can''t list orphaned files');

select pg_temp.as_service();
create temporary table orphans on commit drop as select name from public.post_orphaned_media();
select is((select count(*)::int from orphans where name like '%/abandoned.jpg'), 1, 'a file from a draft that never published is listed');
select is((select count(*)::int from orphans where name like '%/fresh.jpg'), 0, 'a file uploaded in the last day is kept (its post may still publish)');
select is((select count(*)::int from orphans where name like '%/b7100000-0000-0000-0000-000000000001/%'), 0, 'files of a published post are kept');
select is((select count(*)::int from orphans where name like '%/reported.jpg'), 0, 'a file a report refers to is kept');

select pg_temp.act_as('b7000000-0000-0000-0000-00000000000a');
delete from public.posts where id = 'b7100000-0000-0000-0000-000000000001';
select pg_temp.as_service();
select is((select count(*)::int from public.post_orphaned_media() where name like '%/b7100000-0000-0000-0000-000000000001/%'), 2,
  'once the post is deleted, its files are listed');
select is((select count(*)::int from public.post_orphaned_media(1)), 1, 'the limit is honoured');

select * from finish();
rollback;
