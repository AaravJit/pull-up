-- Content reports (20261024000100): a report about a post, comment, meet or
-- profile keeps the server's copy of what was reported, only for content the
-- reporter can see; speed boards stay closed.

begin;
create extension if not exists pgtap with schema extensions;
select plan(14);

insert into auth.users (id, email, raw_user_meta_data) values
  ('c1000000-0000-0000-0000-00000000000a'::uuid, 'cr-reporter@example.com', '{"username":"cr_reporter"}'),
  ('c1000000-0000-0000-0000-00000000000b'::uuid, 'cr-author@example.com', '{"username":"cr_author"}');

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

insert into public.posts (id, author_id, kind, visibility, caption) values
  ('c2000000-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-00000000000b', 'moment', 'public', 'Buy followers at example.test'),
  ('c2000000-0000-0000-0000-000000000002', 'c1000000-0000-0000-0000-00000000000b', 'moment', 'private', 'Only me'),
  ('c2000000-0000-0000-0000-000000000003', 'c1000000-0000-0000-0000-00000000000a', 'moment', 'public', 'My own');
insert into public.comments (id, post_id, author_id, body) values
  ('c3000000-0000-0000-0000-000000000001', 'c2000000-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-00000000000b', 'Spam comment');
insert into public.meets (id, host_id, title, kind, starts_at, ends_at, venue_name, lat, lon) values
  ('c4000000-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-00000000000b', 'Street race night', 'meet',
   now() + interval '1 day', now() + interval '1 day 2 hours', 'Somewhere', 38.5, -121.5);
update public.profile_details set bio = 'DM me for deals' where user_id = 'c1000000-0000-0000-0000-00000000000b';

select pg_temp.act_as('c1000000-0000-0000-0000-00000000000a');
select lives_ok($$ select public.report_content('post', 'c2000000-0000-0000-0000-000000000001', 'spam', 'link in caption') $$, 'a visible post can be reported');
select lives_ok($$ select public.report_content('comment', 'c3000000-0000-0000-0000-000000000001', 'spam') $$, 'a visible comment can be reported');
select lives_ok($$ select public.report_content('meet', 'c4000000-0000-0000-0000-000000000001', 'violence') $$, 'a visible meet can be reported');
select lives_ok($$ select public.report_content('profile', 'c1000000-0000-0000-0000-00000000000b', 'scam') $$, 'a profile can be reported');
select throws_ok($$ select public.report_content('post', 'c2000000-0000-0000-0000-000000000002', 'spam') $$, '42501', null, 'a post you can''t see can''t be reported');
select throws_ok($$ select public.report_content('post', 'c2000000-0000-0000-0000-000000000003', 'spam') $$, '42501', null, 'your own post can''t be reported');
select throws_ok($$ select public.report_content('vehicle', 'c2000000-0000-0000-0000-000000000001', 'spam') $$, '42501', null, 'unknown kinds are refused');

-- The author deletes the post; staff still have what was reported.
select pg_temp.act_as('c1000000-0000-0000-0000-00000000000b');
delete from public.posts where id = 'c2000000-0000-0000-0000-000000000001';
select pg_temp.as_admin();
select is((select snapshot ->> 'caption' from public.reports where snapshot ->> 'content_id' = 'c2000000-0000-0000-0000-000000000001'),
          'Buy followers at example.test', 'the post''s caption is kept after the author deletes it');
select is((select subject_id from public.reports where snapshot ->> 'content_kind' = 'post'),
          'c1000000-0000-0000-0000-00000000000b'::uuid, 'the report names the post''s author, not whoever the app said');
select is((select details from public.reports where snapshot ->> 'content_kind' = 'post'), 'link in caption', 'the reporter''s note is kept');
select is((select snapshot ->> 'body' from public.reports where snapshot ->> 'content_kind' = 'comment'), 'Spam comment', 'the comment is copied');
select is((select snapshot ->> 'bio' from public.reports where snapshot ->> 'content_kind' = 'profile'), 'DM me for deals', 'the profile''s bio is copied');

select pg_temp.act_as('c1000000-0000-0000-0000-00000000000a');
select throws_ok($$ update public.privacy_settings set performance_leaderboard_opt_in = true where user_id = auth.uid() $$,
                 '23514', null, 'nobody can join speed boards');
select pg_temp.as_admin();
set local role anon;
select throws_ok($$ select public.report_content('profile', 'c1000000-0000-0000-0000-00000000000b', 'spam') $$, '42501', null, 'signed-out callers can''t report');

select * from finish();
rollback;
