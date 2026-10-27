-- Reverts 20261025000110_account_deletion_jobs.sql. Unfinished deletion
-- jobs are lost; run delete-account's scheduled pass first so none remain.

drop function if exists public.account_deletions_due(integer);
drop function if exists public.account_deletion_failed(uuid, text, text, text);
drop function if exists public.account_deletion_begin(uuid);

create or replace function private.account_exists()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$ select exists (select 1 from auth.users u where u.id = auth.uid()); $$;

drop table if exists private.account_deletions;
