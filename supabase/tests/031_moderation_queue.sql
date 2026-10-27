-- Report queue (20261025000310): only moderators (or the server) can read
-- or act on it, nobody can make themselves a moderator, every action lands
-- in an append-only audit log, and each report is queued for delivery to
-- the owner's endpoint with retries and a recorded status.

begin;
create extension if not exists pgtap with schema extensions;
select plan(37);

insert into auth.users (id, email, raw_user_meta_data) values
  ('f3100000-0000-0000-0000-00000000000a'::uuid, 'mq-reporter@example.com', '{"username":"mq_reporter"}'),
  ('f3100000-0000-0000-0000-00000000000b'::uuid, 'mq-author@example.com', '{"username":"mq_author"}'),
  ('f3100000-0000-0000-0000-00000000000c'::uuid, 'mq-mod@example.com', '{"username":"mq_mod"}');
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
create or replace function pg_temp.as_service() returns void language plpgsql as $$
begin
  perform set_config('role', 'service_role', true);
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  perform set_config('request.jwt.claim.sub', '', true);
end $$;

insert into public.posts (id, author_id, caption, visibility) values
  ('f3110000-0000-0000-0000-000000000001', 'f3100000-0000-0000-0000-00000000000b', 'Rude caption', 'public');

-- A report is filed and queued for delivery.
select pg_temp.act_as('f3100000-0000-0000-0000-00000000000a');
create temp table rep on commit drop as
  select public.report_content('post', 'f3110000-0000-0000-0000-000000000001', 'violence', 'threat in caption') as id;
grant select on rep to authenticated, service_role;
select pg_temp.as_admin();
select is((select priority from public.reports where id = (select id from rep)), 'urgent', 'threats are urgent');
select is((select content_kind || ':' || content_id from public.reports where id = (select id from rep)),
          'post:f3110000-0000-0000-0000-000000000001', 'the report names the content');
select is((select status from private.moderation_deliveries where report_id = (select id from rep)), 'pending', 'the report waits for delivery');

-- A normal user: no queue, no actions, no self-promotion.
select pg_temp.act_as('f3100000-0000-0000-0000-00000000000a');
select throws_ok($$ select * from public.mod_queue() $$, '42501', 'moderators only', 'a normal user can''t list the queue');
select throws_ok($$ select public.mod_report((select id from rep)) $$, '42501', 'moderators only', 'or open a report');
select throws_ok($$ select public.mod_resolve_report((select id from rep), 'dismissed') $$, '42501', 'moderators only', 'or dismiss it');
select throws_ok($$ select public.mod_set_content_state('post', 'f3110000-0000-0000-0000-000000000001', 'removed') $$, '42501', 'moderators only', 'or remove content');
select throws_ok($$ select public.mod_suspend_user('f3100000-0000-0000-0000-00000000000b', null, 'x') $$, '42501', 'moderators only', 'or suspend someone');
select throws_ok($$ select public.mod_add_term('anything') $$, '42501', 'moderators only', 'or change the term list');
select throws_ok($$ select public.moderation_summary() $$, '42501', 'moderators only', 'or read the summary');
select throws_ok($$ insert into private.moderators (user_id) values (auth.uid()) $$, '42501', null, 'a user can''t make themselves a moderator');
select throws_ok($$ select * from private.moderators $$, '42501', null, 'or read who the moderators are');
select throws_ok($$ select * from private.moderation_audit $$, '42501', null, 'or read the audit log');
select throws_ok($$ select public.moderation_claim_deliveries() $$, '42501', null, 'the worker functions are server only');
select is((select count(*)::int from public.reports where id = (select id from rep)), 1, 'reporters still see their own report');

-- The service role can't add moderators either: only the owner, in the SQL editor.
select pg_temp.as_service();
select throws_ok($$ insert into private.moderators (user_id) values ('f3100000-0000-0000-0000-00000000000a') $$, '42501', null, 'the service role can''t add moderators');

-- The owner adds a moderator; that is audited.
select pg_temp.as_admin();
insert into private.moderators (user_id, note) values ('f3100000-0000-0000-0000-00000000000c', 'test moderator');
select is((select action from private.moderation_audit where subject_id = 'f3100000-0000-0000-0000-00000000000c' order by id desc limit 1),
          'moderator_added', 'adding a moderator is audited');

-- A moderator works the queue.
select pg_temp.act_as('f3100000-0000-0000-0000-00000000000c');
select is((select count(*)::int from public.mod_queue() where report_id = (select id from rep)), 1, 'the moderator sees the report');
select is((select subject_username from public.mod_queue() where report_id = (select id from rep)), 'mq_author', 'with the subject');
select is(public.mod_report((select id from rep)) -> 'report' -> 'snapshot' ->> 'caption', 'Rude caption', 'and the evidence');
select lives_ok($$ select public.mod_resolve_report((select id from rep), 'reviewing', 'looking') $$, 'the moderator can mark it reviewing');
select lives_ok($$ select public.mod_set_content_state('post', 'f3110000-0000-0000-0000-000000000001', 'removed', (select id from rep), 'threat', interval '0 seconds') $$, 'and remove the post');
select ok(public.moderation_summary() ? 'open', 'the moderator can read the summary');
select is(public.mod_check_text('hello'), null, 'and test texts against the list');

-- The audit log records who did what, and can't be rewritten.
select pg_temp.as_admin();
select is((select status from public.reports where id = (select id from rep)), 'actioned', 'removing actions the open reports about it');
select is((select array_agg(action order by id) from private.moderation_audit where report_id = (select id from rep)),
          array['report_reviewing', 'content_removed'], 'each action is in the audit log');
select is((select actor_id from private.moderation_audit where action = 'content_removed' and report_id = (select id from rep)),
          'f3100000-0000-0000-0000-00000000000c'::uuid, 'with the moderator who did it');
select throws_ok($$ update private.moderation_audit set note = 'edited' $$, '42501', 'the moderation audit log is append-only', 'the log can''t be edited, even by the owner');
select throws_ok($$ delete from private.moderation_audit $$, '42501', 'the moderation audit log is append-only', 'or deleted from');
select pg_temp.as_service();
select throws_ok($$ select count(*) from private.moderation_audit $$, '42501', null, 'the service role has no access to it at all');
select pg_temp.as_admin();

-- Removing the moderator is audited, and their access ends.
delete from private.moderators where user_id = 'f3100000-0000-0000-0000-00000000000c';
select pg_temp.act_as('f3100000-0000-0000-0000-00000000000c');
select throws_ok($$ select * from public.mod_queue() $$, '42501', 'moderators only', 'a removed moderator loses access');

-- Delivery: the worker leases the report, a failure backs off, success is recorded.
select pg_temp.as_service();
select is((select count(*)::int from public.moderation_claim_deliveries(10) where report_id = (select id from rep)), 1, 'the worker gets the report');
select is((select count(*)::int from public.moderation_claim_deliveries(10) where report_id = (select id from rep)), 0, 'a leased report isn''t handed out twice');
select public.moderation_record_delivery(array[(select id from rep)], false, 'HTTP 500');
select pg_temp.as_admin();
select ok((select attempts = 1 and status = 'pending' and last_error = 'HTTP 500' and next_attempt_at > now()
           from private.moderation_deliveries where report_id = (select id from rep)), 'a failure is recorded and retried later');
update private.moderation_deliveries set next_attempt_at = now() where report_id = (select id from rep);
select pg_temp.as_service();
select public.moderation_record_delivery(array(select report_id from public.moderation_claim_deliveries(10)), true);
select pg_temp.as_admin();
select ok((select status = 'delivered' and delivered_at is not null and attempts = 2
           from private.moderation_deliveries where report_id = (select id from rep)), 'a delivery is recorded');

-- Evidence survives both accounts being deleted.
delete from auth.users where id in ('f3100000-0000-0000-0000-00000000000a', 'f3100000-0000-0000-0000-00000000000b');
select is((select snapshot ->> 'caption' from public.reports where id = (select id from rep)), 'Rude caption', 'the snapshot outlives the accounts');
select ok((select reporter_id is null and subject_id is null from public.reports where id = (select id from rep)), 'with the account ids cleared');

select * from finish();
rollback;
