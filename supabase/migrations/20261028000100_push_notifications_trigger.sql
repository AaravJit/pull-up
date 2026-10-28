-- Sends each new notification to the send-push function, replacing the
-- dashboard Database Webhook that SUPABASE_SETUP.md used to describe.
-- supabase/tests/042_push_trigger.sql is the proof.
--
-- A dashboard webhook keeps its headers, the push secret included, in the
-- trigger's definition, and it has to be clicked together again on every
-- project. This trigger reads everything from Vault instead, the same way the
-- cron jobs read pullup_cron_secret:
--   pullup_project_url          https://<ref>.supabase.co
--   pullup_anon_key             the project's legacy anon key (a JWT, eyJ...);
--                               send-push keeps Supabase's JWT check, which
--                               rejects an sb_publishable_ key
--   pullup_push_webhook_secret  the same value as the PUSH_WEBHOOK_SECRET
--                               function secret
--
-- Until pg_net is enabled and all three secrets exist, the trigger does
-- nothing, so migrations and tests run anywhere. It never makes an insert
-- fail: a problem is logged as a warning and the notification is kept (it is
-- in the app's list either way). pg_net sends the request after the insert
-- commits, and only the notification id goes in the body; send-push re-reads
-- everything else (public.push_content) and pushes each notification once.
--
-- Don't also add a dashboard webhook on public.notifications: both would
-- call send-push for every row.
--
-- Reversible: supabase/rollback/20261028000100_push_notifications_trigger_down.sql.
-- No data is touched.

create or replace function private.queue_push()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_url text;
  v_key text;
  v_secret text;
begin
  if to_regclass('vault.decrypted_secrets') is null
     or to_regprocedure('net.http_post(text, jsonb, jsonb, jsonb, integer)') is null then
    return null;
  end if;

  execute $q$
    select max(decrypted_secret) filter (where name = 'pullup_project_url'),
           max(decrypted_secret) filter (where name = 'pullup_anon_key'),
           max(decrypted_secret) filter (where name = 'pullup_push_webhook_secret')
      from vault.decrypted_secrets
     where name in ('pullup_project_url', 'pullup_anon_key', 'pullup_push_webhook_secret')
  $q$ into v_url, v_key, v_secret;
  if v_url is null or v_key is null or v_secret is null then
    return null;
  end if;

  execute 'select net.http_post(url := $1, body := $2, params := $3, headers := $4, timeout_milliseconds := $5)'
    using rtrim(v_url, '/') || '/functions/v1/send-push',
          jsonb_build_object('record', jsonb_build_object('id', new.id)),
          '{}'::jsonb,
          jsonb_build_object(
            'Content-Type', 'application/json',
            'Authorization', 'Bearer ' || v_key,
            'x-pullup-webhook-secret', v_secret),
          5000;
  return null;
exception when others then
  raise warning 'push for notification % not queued: %', new.id, sqlerrm;
  return null;
end;
$$;

revoke all on function private.queue_push() from public, anon, authenticated, service_role;

create trigger notifications_push
  after insert on public.notifications
  for each row execute function private.queue_push();
