-- Account deletion: no uploads once the account is gone.
--
-- delete-account removes the person's files and then their auth user. Their
-- access token is a JWT that stays valid until it expires (jwt_expiry, an
-- hour), so a phone still signed in could upload into "<uid>/..." after the
-- account was deleted, and those files would belong to no account and no
-- retry would ever find them. Uploads to avatars, vehicle-media and
-- post-media now also need the auth user to exist. dm-media uploads already
-- need a conversation membership, which is deleted with the account.

create function private.account_exists()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$ select exists (select 1 from auth.users u where u.id = auth.uid()); $$;
revoke execute on function private.account_exists() from public, anon;
grant execute on function private.account_exists() to authenticated;

alter policy "Storage: upload into your own folder" on storage.objects
  with check (
    bucket_id in ('avatars', 'vehicle-media', 'post-media')
    and (storage.foldername(name))[1] = auth.uid()::text
    and private.within_storage_quota()
    and private.account_exists()
  );
