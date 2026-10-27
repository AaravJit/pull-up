-- Write rate limits (20261025000320 and report_user in 20261025000310):
-- direct API writes trip them, deleting doesn't give slots back, and one
-- account's limit doesn't touch another's.

begin;
create extension if not exists pgtap with schema extensions;
select plan(12);

insert into auth.users (id, email, raw_user_meta_data) values
  ('f3400000-0000-0000-0000-00000000000a'::uuid, 'rl-ann@example.com', '{"username":"rl_ann"}'),
  ('f3400000-0000-0000-0000-00000000000b'::uuid, 'rl-ben@example.com', '{"username":"rl_ben"}');
-- These accounts confirmed the minimum age and accepted the current terms
-- (20261025000400); 040/041 test what happens without that.
insert into public.terms_acceptances (user_id, version)
select p.id, v.version from public.profiles p, public.terms_versions v where v.is_current on conflict do nothing;
insert into private.age_checks (user_id, meets_minimum, minimum_age, method)
select id, true, 13, 'self_declared' from public.profiles on conflict do nothing;
insert into auth.users (id, email)
select ('f34' || lpad(i::text, 5, '0') || '-ff00-0000-0000-000000000000')::uuid, 'rl-' || i || '@example.com' from generate_series(1, 31) as i;
-- These accounts confirmed the minimum age and accepted the current terms
-- (20261025000400); 040/041 test what happens without that.
insert into public.terms_acceptances (user_id, version)
select p.id, v.version from public.profiles p, public.terms_versions v where v.is_current on conflict do nothing;
insert into private.age_checks (user_id, meets_minimum, minimum_age, method)
select id, true, 13, 'self_declared' from public.profiles on conflict do nothing;

create or replace function pg_temp.act_as(uid uuid) returns void language plpgsql as $$
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', uid::text, true);
end $$;

insert into public.posts (id, author_id, caption, visibility) values
  ('f3410000-0000-0000-0000-000000000001', 'f3400000-0000-0000-0000-00000000000b', 'Ben''s post', 'public');

select pg_temp.act_as('f3400000-0000-0000-0000-00000000000a');

-- Posts: 5 a minute, even when each is deleted straight away.
select lives_ok($$ do $d$ begin for i in 1..5 loop
  insert into public.posts (author_id, caption) values (auth.uid(), 'post ' || i);
  delete from public.posts where author_id = auth.uid();
end loop; end $d$ $$, 'five posts in a minute are fine');
select throws_ok($$ insert into public.posts (author_id, caption) values (auth.uid(), 'sixth') $$, '54000',
  'You''re doing that a lot. Wait a few minutes and try again.', 'the sixth is refused, though the others were deleted');

-- Comments: 10 a minute.
select lives_ok($$ insert into public.comments (post_id, author_id, body) select 'f3410000-0000-0000-0000-000000000001', auth.uid(), 'c' || i from generate_series(1, 10) i $$, 'ten comments are fine');
select throws_ok($$ insert into public.comments (post_id, author_id, body) values ('f3410000-0000-0000-0000-000000000001', auth.uid(), 'eleven') $$, '54000', null, 'the eleventh is refused');

-- Follows: 30 a minute, unfollowing included.
select lives_ok($$ insert into public.follows (follower_id, followee_id)
  select auth.uid(), ('f34' || lpad(i::text, 5, '0') || '-ff00-0000-0000-000000000000')::uuid from generate_series(1, 30) i $$, 'thirty follows are fine');
delete from public.follows where follower_id = auth.uid();
select throws_ok($$ insert into public.follows (follower_id, followee_id) values (auth.uid(), 'f3400031-ff00-0000-0000-000000000000') $$, '54000', null, 'the next is refused after unfollowing everyone');

-- Meets: 3 a minute.
select lives_ok($$ insert into public.meets (host_id, title, starts_at, ends_at, venue_name, lat, lon)
  select auth.uid(), 'Meet ' || i, now() + interval '1 day', now() + interval '1 day 1 hour', 'Lot', 1, 1 from generate_series(1, 3) i $$, 'three meets are fine');
select throws_ok($$ insert into public.meets (host_id, title, starts_at, ends_at, venue_name, lat, lon)
  values (auth.uid(), 'Meet 4', now() + interval '1 day', now() + interval '1 day 1 hour', 'Lot', 1, 1) $$, '54000', null, 'the fourth is refused');

-- Reports: 5 a minute.
select lives_ok($$ do $d$ begin for i in 1..5 loop
  perform public.report_user('f3400000-0000-0000-0000-00000000000b', 'spam');
end loop; end $d$ $$, 'five reports are fine');
select throws_ok($$ select public.report_user('f3400000-0000-0000-0000-00000000000b', 'spam') $$, '54000', null, 'the sixth is refused');

-- Another account has its own allowance.
select pg_temp.act_as('f3400000-0000-0000-0000-00000000000b');
select lives_ok($$ insert into public.posts (author_id, caption) values (auth.uid(), 'Ben posts') $$, 'Ben isn''t limited by Ann');

-- The server isn't limited.
select set_config('role', 'postgres', true);
select set_config('request.jwt.claims', '', true);
select set_config('request.jwt.claim.sub', '', true);
select lives_ok($$ insert into public.posts (author_id, caption) values ('f3400000-0000-0000-0000-00000000000a', 'imported') $$, 'server writes aren''t limited');

select * from finish();
rollback;
