-- Messaging pauses (20261025000330): other signed-in users can't tell that
-- someone's messaging is paused, the paused person can see it through
-- my_moderation_status() and still can't message, moderators see it on a
-- report, and nobody can set or lift a pause through the API.

begin;
create extension if not exists pgtap with schema extensions;
select plan(13);

insert into auth.users (id, email, raw_user_meta_data) values
  ('f3500000-0000-0000-0000-00000000000a'::uuid, 'mp-ann@example.com', '{"username":"mp_ann"}'),
  ('f3500000-0000-0000-0000-00000000000b'::uuid, 'mp-ben@example.com', '{"username":"mp_ben"}'),
  ('f3500000-0000-0000-0000-00000000000c'::uuid, 'mp-mod@example.com', '{"username":"mp_mod"}');
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
create or replace function pg_temp.as_admin() returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
end $$;

-- Ann's messaging is paused; Ben reports her.
insert into private.messaging_pauses (user_id, paused_until, note)
  values ('f3500000-0000-0000-0000-00000000000a', now() + interval '3 days', 'spam DMs');
insert into private.moderators (user_id, note) values ('f3500000-0000-0000-0000-00000000000c', 'test');
select is((select action from private.moderation_audit where subject_id = 'f3500000-0000-0000-0000-00000000000a' order by id desc limit 1),
          'messaging_paused', 'pausing is audited');
select throws_ok($$ update public.profiles set messaging_suspended_until = now() + interval '1 day' where id = 'f3500000-0000-0000-0000-00000000000a' $$,
  '23514', null, 'the old profile column can''t be used any more');

-- Ben, another signed-in user, sees nothing.
select pg_temp.act_as('f3500000-0000-0000-0000-00000000000b');
select is((select count(*)::int from public.profiles where id = 'f3500000-0000-0000-0000-00000000000a'), 1, 'Ben can see Ann''s profile');
select is((select messaging_suspended_until from public.profiles where id = 'f3500000-0000-0000-0000-00000000000a'), null,
  'but not that her messaging is paused');
select throws_ok($$ select * from private.messaging_pauses $$, '42501', null, 'and can''t read the pauses');
select is(public.my_moderation_status() ->> 'messaging_paused_until', null, 'his own status shows no pause');
create temp table rep on commit drop as select public.report_user('f3500000-0000-0000-0000-00000000000a', 'spam') as id;
grant select on rep to authenticated;
select throws_ok($$ select public.mod_report((select id from rep)) $$, '42501', 'moderators only', 'or open the report to find out');

-- Ann sees her own pause, still can't message, and can't lift it.
select pg_temp.act_as('f3500000-0000-0000-0000-00000000000a');
select isnt(public.my_moderation_status() ->> 'messaging_paused_until', null, 'Ann sees her pause in her own status');
select is(public.my_moderation_status() ->> 'suspended', 'false', 'which isn''t a full suspension');
select throws_ok($$ select public.start_conversation('f3500000-0000-0000-0000-00000000000b') $$, '42501',
  'messaging is paused on your account', 'and she still can''t start a conversation');
select throws_ok($$ delete from private.messaging_pauses where user_id = auth.uid() $$, '42501', null, 'or lift the pause');

-- A moderator sees it on the report.
select pg_temp.act_as('f3500000-0000-0000-0000-00000000000c');
select isnt(public.mod_report((select id from rep)) ->> 'subject_messaging_paused_until', null, 'a moderator sees the pause on the report');

-- Lifting it lets Ann message again.
select pg_temp.as_admin();
delete from private.messaging_pauses where user_id = 'f3500000-0000-0000-0000-00000000000a';
select pg_temp.act_as('f3500000-0000-0000-0000-00000000000a');
select lives_ok($$ select public.start_conversation('f3500000-0000-0000-0000-00000000000b') $$, 'after it''s lifted she can message');

select * from finish();
rollback;
