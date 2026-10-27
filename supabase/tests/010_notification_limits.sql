-- Security re-check G4 (docs/SECURITY_REPORT.md): toggling a like or a
-- follow, or posting comment after comment, can't flood someone's
-- notifications.

begin;
create extension if not exists pgtap with schema extensions;
select plan(6);

insert into auth.users (id, email, raw_user_meta_data) values
  ('ea000000-0000-0000-0000-00000000000a', 'limit-ann@example.com', '{"username":"limit_ann"}'),
  ('ea000000-0000-0000-0000-00000000000b', 'limit-ben@example.com', '{"username":"limit_ben"}'),
  ('ea000000-0000-0000-0000-00000000000c', 'limit-cat@example.com', '{"username":"limit_cat"}');

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

create or replace function pg_temp.count_for(k text, actor uuid) returns int language sql as $$
  select count(*)::int from public.notifications
  where recipient_id = 'ea000000-0000-0000-0000-00000000000a' and kind = k and actor_id = actor;
$$;

select pg_temp.act_as('ea000000-0000-0000-0000-00000000000a');
insert into public.posts (id, author_id, kind, caption, visibility)
values ('ea100000-0000-0000-0000-000000000001', auth.uid(), 'moment', 'Sunday', 'public');

-- Ben likes and unlikes five times, and follows and unfollows five times.
select pg_temp.act_as('ea000000-0000-0000-0000-00000000000b');
do $$
begin
  for i in 1..5 loop
    insert into public.likes (post_id, user_id) values ('ea100000-0000-0000-0000-000000000001', auth.uid());
    delete from public.likes where post_id = 'ea100000-0000-0000-0000-000000000001' and user_id = auth.uid();
    insert into public.follows (follower_id, followee_id) values (auth.uid(), 'ea000000-0000-0000-0000-00000000000a');
    delete from public.follows where follower_id = auth.uid() and followee_id = 'ea000000-0000-0000-0000-00000000000a';
  end loop;
end $$;

select pg_temp.as_admin();
select is(pg_temp.count_for('like', 'ea000000-0000-0000-0000-00000000000b'), 1, 'G4: liking the same post again doesn''t notify again');
select is(pg_temp.count_for('follow', 'ea000000-0000-0000-0000-00000000000b'), 1, 'G4: following again doesn''t notify again');

-- Then posts 40 comments. Comments are rate limited too (10 a minute,
-- 20261025000320), so the limit's log is cleared between batches of ten:
-- this test is about notifications.
do $$
begin
  for batch in 0..3 loop
    perform pg_temp.as_admin();
    delete from private.function_calls where user_id = 'ea000000-0000-0000-0000-00000000000b';
    perform pg_temp.act_as('ea000000-0000-0000-0000-00000000000b');
    insert into public.comments (post_id, author_id, body)
    select 'ea100000-0000-0000-0000-000000000001', auth.uid(), 'comment ' || (batch * 10 + i) from generate_series(1, 10) as i;
  end loop;
end $$;
select pg_temp.act_as('ea000000-0000-0000-0000-00000000000b');
select is((select count(*)::int from public.comments where post_id = 'ea100000-0000-0000-0000-000000000001'), 40,
  'G4: every comment is still posted');

select pg_temp.as_admin();
select is((select count(*)::int from public.notifications
           where recipient_id = 'ea000000-0000-0000-0000-00000000000a' and actor_id = 'ea000000-0000-0000-0000-00000000000b'), 30,
  'G4: one person sends at most 30 notifications an hour to another');

-- Cat isn't affected by Ben's limit.
select pg_temp.act_as('ea000000-0000-0000-0000-00000000000c');
insert into public.likes (post_id, user_id) values ('ea100000-0000-0000-0000-000000000001', auth.uid());
insert into public.comments (post_id, author_id, body) values ('ea100000-0000-0000-0000-000000000001', auth.uid(), 'Nice');
select pg_temp.as_admin();
select is(pg_temp.count_for('like', 'ea000000-0000-0000-0000-00000000000c'), 1, 'G4: someone else''s like still notifies');
select is(pg_temp.count_for('comment', 'ea000000-0000-0000-0000-00000000000c'), 1, 'G4: and so does their comment');

select * from finish();
rollback;
