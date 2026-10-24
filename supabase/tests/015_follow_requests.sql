-- Follow requests (APP_AUDIT.md §5.1). With "Approve new followers" on, a
-- follow is pending until the followee accepts (update to accepted) or
-- declines (delete). These are the queries the app sends; RLS decides.

begin;
create extension if not exists pgtap with schema extensions;
select plan(16);

insert into auth.users (id, email, raw_user_meta_data) values
  ('f1500000-0000-0000-0000-00000000000a', 'req-owen@example.com', '{"username":"req_owen"}'),
  ('f1500000-0000-0000-0000-00000000000b', 'req-fay@example.com', '{"username":"req_fay"}'),
  ('f1500000-0000-0000-0000-00000000000c', 'req-dee@example.com', '{"username":"req_dee"}'),
  ('f1500000-0000-0000-0000-00000000000d', 'req-tom@example.com', '{"username":"req_tom"}');

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

create or replace function pg_temp.status(follower uuid) returns text language sql as $$
  select status from public.follows where follower_id = follower and followee_id = 'f1500000-0000-0000-0000-00000000000a';
$$;

-- Owen approves new followers and follows Fay back. Fay and Dee ask to
-- follow him. Tom is a third party.
select pg_temp.act_as('f1500000-0000-0000-0000-00000000000a');
update public.privacy_settings set require_follow_approval = true;
insert into public.follows (follower_id, followee_id) values (auth.uid(), 'f1500000-0000-0000-0000-00000000000b');
select pg_temp.act_as('f1500000-0000-0000-0000-00000000000b');
insert into public.follows (follower_id, followee_id) values (auth.uid(), 'f1500000-0000-0000-0000-00000000000a');
select pg_temp.act_as('f1500000-0000-0000-0000-00000000000c');
insert into public.follows (follower_id, followee_id) values (auth.uid(), 'f1500000-0000-0000-0000-00000000000a');

-- 1–4: requests are pending and the followee can list them -------------------------
select pg_temp.as_admin();
select is(pg_temp.status('f1500000-0000-0000-0000-00000000000b'), 'pending', 'a follow of someone who approves followers is pending');
select is((select count(*)::int from public.notifications
           where recipient_id = 'f1500000-0000-0000-0000-00000000000a' and kind = 'follow_request'), 2,
  'the followee gets a follow_request notification for each');
select pg_temp.act_as('f1500000-0000-0000-0000-00000000000a');
select is((select count(*)::int from public.follows f join public.profiles p on p.id = f.follower_id
           where f.followee_id = auth.uid() and f.status = 'pending'), 2,
  'the followee lists both requests with the requester''s profile');
select pg_temp.act_as('f1500000-0000-0000-0000-00000000000d');
select is((select count(*)::int from public.follows where followee_id = 'f1500000-0000-0000-0000-00000000000a'), 0,
  'a third party can''t see pending requests');

-- 5–8: only the followee can accept -------------------------------------------------
select pg_temp.act_as('f1500000-0000-0000-0000-00000000000b');
update public.follows set status = 'accepted'
where follower_id = 'f1500000-0000-0000-0000-00000000000b' and followee_id = 'f1500000-0000-0000-0000-00000000000a';
select pg_temp.as_admin();
select is(pg_temp.status('f1500000-0000-0000-0000-00000000000b'), 'pending', 'the follower can''t accept their own request');

select pg_temp.act_as('f1500000-0000-0000-0000-00000000000d');
update public.follows set status = 'accepted'
where follower_id = 'f1500000-0000-0000-0000-00000000000b' and followee_id = 'f1500000-0000-0000-0000-00000000000a';
select pg_temp.as_admin();
select is(pg_temp.status('f1500000-0000-0000-0000-00000000000b'), 'pending', 'a third party can''t accept a request');

select pg_temp.act_as('f1500000-0000-0000-0000-00000000000d');
delete from public.follows
where follower_id = 'f1500000-0000-0000-0000-00000000000b' and followee_id = 'f1500000-0000-0000-0000-00000000000a';
select pg_temp.as_admin();
select is(pg_temp.status('f1500000-0000-0000-0000-00000000000b'), 'pending', 'a third party can''t decline a request');

select pg_temp.act_as('f1500000-0000-0000-0000-00000000000b');
select is(public.is_friend('f1500000-0000-0000-0000-00000000000a', 'f1500000-0000-0000-0000-00000000000b'), false,
  'a pending request doesn''t make friends');

-- 9–12: the followee accepts Fay ----------------------------------------------------
select pg_temp.act_as('f1500000-0000-0000-0000-00000000000a');
update public.follows set status = 'accepted'
where follower_id = 'f1500000-0000-0000-0000-00000000000b' and followee_id = auth.uid() and status = 'pending';
select pg_temp.as_admin();
select is(pg_temp.status('f1500000-0000-0000-0000-00000000000b'), 'accepted', 'the followee accepts a request');
select pg_temp.act_as('f1500000-0000-0000-0000-00000000000b');
select is(public.is_friend('f1500000-0000-0000-0000-00000000000a', 'f1500000-0000-0000-0000-00000000000b'), true,
  'once accepted, a mutual follow makes friends');
select is((public.get_profile('f1500000-0000-0000-0000-00000000000a') ->> 'follower_count')::int, 1,
  'the accepted follower counts');

select pg_temp.act_as('f1500000-0000-0000-0000-00000000000a');
select throws_ok(
  $$ update public.follows set status = 'pending'
     where follower_id = 'f1500000-0000-0000-0000-00000000000b' and followee_id = auth.uid() $$,
  '42501', null, 'an accepted follow can''t be put back to pending');

-- 13–14: the followee declines Dee --------------------------------------------------
delete from public.follows
where follower_id = 'f1500000-0000-0000-0000-00000000000c' and followee_id = auth.uid() and status = 'pending';
select pg_temp.as_admin();
select is(pg_temp.status('f1500000-0000-0000-0000-00000000000c'), null, 'the followee declines a request');
select pg_temp.act_as('f1500000-0000-0000-0000-00000000000a');
select is((select count(*)::int from public.follows where followee_id = auth.uid() and status = 'pending'), 0,
  'no requests are left');

-- 15–16: a follower can't skip approval, but can withdraw ---------------------------
select pg_temp.act_as('f1500000-0000-0000-0000-00000000000d');
insert into public.follows (follower_id, followee_id, status) values (auth.uid(), 'f1500000-0000-0000-0000-00000000000a', 'accepted');
select pg_temp.as_admin();
select is(pg_temp.status('f1500000-0000-0000-0000-00000000000d'), 'pending', 'a follow inserted as accepted is still pending');
select pg_temp.act_as('f1500000-0000-0000-0000-00000000000d');
delete from public.follows where follower_id = auth.uid() and followee_id = 'f1500000-0000-0000-0000-00000000000a';
select pg_temp.as_admin();
select is(pg_temp.status('f1500000-0000-0000-0000-00000000000d'), null, 'the follower can withdraw their request');

select * from finish();
rollback;
