-- Push trigger (20261028000100): each new notification asks send-push to
-- deliver it, with the secrets read from Vault, and only once Vault holds all
-- three. An insert never fails because of it. Where pg_net or Vault isn't
-- installed (the local harness), stand-ins with the same shape are created
-- inside this transaction; on the CLI stack the real extensions are used.

begin;
create extension if not exists pgtap with schema extensions;
select plan(13);

do $$
begin
  if to_regprocedure('net.http_post(text, jsonb, jsonb, jsonb, integer)') is null then
    create schema if not exists net;
    create table net.http_request_queue (id bigserial, method text, url text, headers jsonb, body bytea, timeout_milliseconds int);
    create function net.http_post(url text, body jsonb default '{}', params jsonb default '{}',
                                  headers jsonb default '{}', timeout_milliseconds int default 5000)
      returns bigint language sql as $f$
        insert into net.http_request_queue (method, url, headers, body, timeout_milliseconds)
        values ('POST', url, headers, convert_to(body::text, 'utf8'), timeout_milliseconds) returning id
      $f$;
  end if;
  if to_regclass('vault.decrypted_secrets') is null then
    create schema if not exists vault;
    create table vault.secrets (name text primary key, secret text);
    create view vault.decrypted_secrets as select name, secret as decrypted_secret from vault.secrets;
    create function vault.create_secret(new_secret text, new_name text) returns uuid language sql as $f$
      insert into vault.secrets values (new_name, new_secret); select gen_random_uuid()
    $f$;
  end if;
end $$;

create or replace function pg_temp.queued() returns bigint language sql as $$
  select count(*) from net.http_request_queue where url like '%/functions/v1/send-push'
$$;

insert into auth.users (id, email, raw_user_meta_data) values
  ('c6000000-0000-0000-0000-00000000000a', 'push-ann@example.com', '{"username":"push_ann"}'),
  ('c6000000-0000-0000-0000-00000000000b', 'push-ben@example.com', '{"username":"push_ben"}');

select has_trigger('public', 'notifications', 'notifications_push', 'new notifications have a push trigger');
select ok((select prosecdef from pg_proc where oid = 'private.queue_push()'::regprocedure),
  'it runs as its owner, so it can read Vault');
select ok((select proconfig @> array['search_path=""'] from pg_proc where oid = 'private.queue_push()'::regprocedure),
  'with an empty search_path');
select ok(not has_function_privilege('authenticated', 'private.queue_push()', 'execute')
      and not has_function_privilege('anon', 'private.queue_push()', 'execute'),
  'no API role can call it');

-- Nothing is configured yet: no request, and the insert works.
create temp table base as select pg_temp.queued() as n;
select lives_ok($$
  insert into public.notifications (id, recipient_id, actor_id, kind)
  values ('c6100000-0000-0000-0000-000000000001', 'c6000000-0000-0000-0000-00000000000a', 'c6000000-0000-0000-0000-00000000000b', 'follow')
$$, 'a notification is kept when push isn''t configured');
select is(pg_temp.queued(), (select n from base), 'and no request is made');

-- Two of the three secrets are still not enough.
select vault.create_secret('https://example-ref.supabase.co/', 'pullup_project_url');
select vault.create_secret('test-anon-key', 'pullup_anon_key');
insert into public.notifications (recipient_id, actor_id, kind)
values ('c6000000-0000-0000-0000-00000000000a', 'c6000000-0000-0000-0000-00000000000b', 'like');
select is(pg_temp.queued(), (select n from base), 'nothing is sent until the webhook secret is in Vault too');

-- All three: one request per notification, to send-push, with the headers.
select vault.create_secret('test-webhook-secret', 'pullup_push_webhook_secret');
insert into public.notifications (id, recipient_id, actor_id, kind)
values ('c6100000-0000-0000-0000-000000000002', 'c6000000-0000-0000-0000-00000000000a', 'c6000000-0000-0000-0000-00000000000b', 'comment');
select is(pg_temp.queued(), (select n from base) + 1, 'a configured project queues one request');

select is((select url from net.http_request_queue where url like '%/send-push' order by id desc limit 1),
  'https://example-ref.supabase.co/functions/v1/send-push', 'to the project''s send-push function');
select is((select headers ->> 'x-pullup-webhook-secret' from net.http_request_queue where url like '%/send-push' order by id desc limit 1),
  'test-webhook-secret', 'with the webhook secret send-push checks');
select is((select headers ->> 'Authorization' from net.http_request_queue where url like '%/send-push' order by id desc limit 1),
  'Bearer test-anon-key', 'and the anon key for the JWT check');
select is((select convert_from(body, 'utf8')::jsonb from net.http_request_queue where url like '%/send-push' order by id desc limit 1),
  '{"record": {"id": "c6100000-0000-0000-0000-000000000002"}}'::jsonb,
  'the body is only the notification id');

-- A notification made by the app's own triggers is pushed the same way.
create temp table counts as
  select pg_temp.queued() as queued, (select count(*) from public.notifications) as notes;
insert into public.follows (follower_id, followee_id)
values ('c6000000-0000-0000-0000-00000000000a', 'c6000000-0000-0000-0000-00000000000b');
select ok((select count(*) from public.notifications) - notes >= 1
      and pg_temp.queued() - queued = (select count(*) from public.notifications) - notes,
  'a follow''s notification is queued as well') from counts;

select * from finish();
rollback;
