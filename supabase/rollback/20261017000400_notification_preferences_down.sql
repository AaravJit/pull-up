-- Reverts 20261017000400_notification_preferences.sql. Guarded when people
-- have saved preferences (they'd fall back to every push on, previews off).
-- Device tokens are kept; only the direct-write policy comes back.
do $$
begin
  if exists (select 1 from public.notification_preferences)
     and coalesce(current_setting('pullup.allow_destructive_rollback', true), '') <> 'on' then
    raise exception 'notification preferences exist; export them and set pullup.allow_destructive_rollback = on to proceed';
  end if;
end $$;

drop function if exists public.unregister_device_token(text);
drop function if exists public.register_device_token(text, text);
drop policy if exists "Device tokens: own removes" on public.device_tokens;
drop policy if exists "Device tokens: own reads" on public.device_tokens;
grant insert, update on public.device_tokens to anon, authenticated;
create policy "Device tokens: own"
  on public.device_tokens for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

drop function if exists public.push_content(uuid);
drop function if exists private.push_category(text);
drop table if exists public.notification_preferences;
