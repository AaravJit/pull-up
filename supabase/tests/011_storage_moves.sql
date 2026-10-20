-- Security re-check G11 (docs/SECURITY_REPORT.md): a file can't be moved
-- into a bucket its owner can't upload to.

begin;
create extension if not exists pgtap with schema extensions;
select plan(2);

insert into auth.users (id, email, raw_user_meta_data) values
  ('eb000000-0000-0000-0000-00000000000a', 'move-ann@example.com', '{"username":"move_ann"}');

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
