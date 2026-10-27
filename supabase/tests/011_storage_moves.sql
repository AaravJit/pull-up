-- Security re-check G11 (docs/SECURITY_REPORT.md): a file can't be moved
-- into a bucket its owner can't upload to.

begin;
create extension if not exists pgtap with schema extensions;
select plan(2);

insert into auth.users (id, email, raw_user_meta_data) values
  ('eb000000-0000-0000-0000-00000000000a', 'move-ann@example.com', '{"username":"move_ann"}');
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

select pg_temp.act_as('eb000000-0000-0000-0000-00000000000a');
insert into storage.objects (id, bucket_id, name)
values ('eb100000-0000-0000-0000-000000000001', 'avatars', 'eb000000-0000-0000-0000-00000000000a/me.jpg');

select throws_ok(
  $$ update storage.objects set bucket_id = 'dm-media' where id = 'eb100000-0000-0000-0000-000000000001' $$,
  '42501', null, 'G11: a file can''t be moved into the DM bucket');
select lives_ok(
  $$ update storage.objects set name = 'eb000000-0000-0000-0000-00000000000a/me-2.jpg' where id = 'eb100000-0000-0000-0000-000000000001' $$,
  'G11: renaming within your own folder still works');

select * from finish();
rollback;
