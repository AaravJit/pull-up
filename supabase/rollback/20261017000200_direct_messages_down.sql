-- Reverts 20261017000200_direct_messages.sql. DESTRUCTIVE for conversations,
-- messages and reports; guarded. Files in the dm-media bucket are left for a
-- deliberate cleanup through the Storage API (see the storage rollback).
do $$
begin
  if (exists (select 1 from public.messages) or exists (select 1 from public.reports))
     and coalesce(current_setting('pullup.allow_destructive_rollback', true), '') <> 'on' then
    raise exception 'messages or reports exist; export them and set pullup.allow_destructive_rollback = on to proceed';
  end if;
end $$;

drop policy if exists "DM media: upload into your conversations" on storage.objects;
drop policy if exists "DM media: sender removes own files" on storage.objects;
drop policy if exists "DM media: readable with the message" on storage.objects;
drop function if exists private.dm_path_member(text, uuid);

do $$
begin
  alter publication supabase_realtime drop table public.messages, public.message_reactions;
exception when undefined_object then null;
end $$;

drop function if exists public.dm_purge();
drop function if exists public.report_user(uuid, text, text, uuid);
drop function if exists public.shared_preview(text, uuid);
drop function if exists public.unread_message_counts();
drop function if exists public.inbox(text, timestamptz, integer);
drop function if exists public.peer_read_at(uuid);
drop function if exists public.unsend_message(uuid);
drop function if exists public.hide_conversation(uuid, boolean);
drop function if exists public.set_conversation_muted(uuid, boolean);
drop function if exists public.respond_to_request(uuid, boolean);
drop function if exists public.mark_conversation_read(uuid);
drop function if exists public.start_conversation(uuid);

delete from public.notifications where kind in ('message', 'message_request');
alter table public.notifications drop constraint notifications_kind_check;
alter table public.notifications add constraint notifications_kind_check
  check (kind in ('follow', 'follow_request', 'like', 'comment', 'meet_rsvp', 'meet_updated', 'meet_cancelled',
                  'meet_starting_soon', 'drive_validated'));
alter table public.notifications drop column if exists conversation_id;

drop table if exists public.reports;
drop table if exists public.message_reactions;
drop table if exists public.messages;
drop function if exists private.after_message();
drop function if exists private.guard_message();
drop function if exists private.can_read_message(uuid);
drop function if exists private.can_view_shared(text, uuid);
drop table if exists public.conversation_members;
drop table if exists public.conversations;
drop function if exists private.peer_of(uuid, uuid);
drop function if exists private.is_member(uuid, uuid);

-- Restore the 20261017000100_accounts.sql definition.
create or replace function private.protect_profile_columns()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not private.is_trusted() then
    if tg_op = 'INSERT' then
      new.is_verified_organizer := false;
      new.onboarded_at := null;
    else
      new.is_verified_organizer := old.is_verified_organizer;
      new.onboarded_at := old.onboarded_at;
      new.id := old.id;
    end if;
  end if;
  return new;
end;
$$;

alter table public.profiles drop column if exists messaging_suspended_until;
alter table public.privacy_settings drop column if exists dm_read_receipts;
alter table public.privacy_settings drop column if exists messages_from;
