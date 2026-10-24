-- Drives whose vehicle was deleted (20261024000200): a drive uploaded after
-- its vehicle is gone is kept as a guest drive instead of being refused for
-- good, while someone else's vehicle is still never attached.

begin;
create extension if not exists pgtap with schema extensions;
select plan(7);

insert into auth.users (id, email, raw_user_meta_data) values
  ('dd000000-0000-0000-0000-00000000000a', 'deleted-ann@example.com', '{"username":"deleted_ann"}'),
  ('dd000000-0000-0000-0000-00000000000b', 'deleted-ben@example.com', '{"username":"deleted_ben"}');

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

-- A drive of the signed-in user's, recorded against `vehicle`.
create or replace function pg_temp.drive(p_id uuid, vehicle uuid) returns void language sql as $$
  insert into public.drives (id, owner_id, vehicle_id, started_at, ended_at, distance_m, moving_s, stopped_s, elapsed_s, top_speed_mps)
  values (p_id, auth.uid(), vehicle, now() - interval '2 hours', now() - interval '2 hours' + interval '299 seconds',
          898, 299, 0, 299, 3);
$$;

-- Ben has a public vehicle and a private one; Ann has one she keeps and one
-- she deletes before her drive in it uploads.
select pg_temp.act_as('dd000000-0000-0000-0000-00000000000b');
insert into public.vehicles (id, owner_id, kind, make, model, year, visibility) values
  ('dd100000-0000-0000-0000-0000000000b1', 'dd000000-0000-0000-0000-00000000000b', 'car', 'Honda', 'S2000', 2004, 'public'),
  ('dd100000-0000-0000-0000-0000000000b2', 'dd000000-0000-0000-0000-00000000000b', 'car', 'Lotus', 'Elise', 2008, 'private');
select pg_temp.act_as('dd000000-0000-0000-0000-00000000000a');
insert into public.vehicles (id, owner_id, kind, make, model, year) values
  ('dd100000-0000-0000-0000-0000000000a1', 'dd000000-0000-0000-0000-00000000000a', 'car', 'Mazda', 'MX-5', 1991),
  ('dd100000-0000-0000-0000-0000000000a2', 'dd000000-0000-0000-0000-00000000000a', 'car', 'Toyota', 'GR86', 2023);
delete from public.vehicles where id = 'dd100000-0000-0000-0000-0000000000a2';

-- 1–2: a drive recorded against the deleted vehicle is stored as a guest drive.
select lives_ok($$ select pg_temp.drive('dd200000-0000-0000-0000-000000000001', 'dd100000-0000-0000-0000-0000000000a2') $$,
  'a drive whose vehicle was deleted is accepted');
select is((select vehicle_id from public.drives where id = 'dd200000-0000-0000-0000-000000000001'), null::uuid,
  'and is stored without the vehicle, as on delete set null leaves stored drives');

-- 3: the driver's own vehicle is still kept.
select pg_temp.drive('dd200000-0000-0000-0000-000000000002', 'dd100000-0000-0000-0000-0000000000a1');
select is((select vehicle_id from public.drives where id = 'dd200000-0000-0000-0000-000000000002'),
  'dd100000-0000-0000-0000-0000000000a1'::uuid, 'a drive in the driver''s own vehicle keeps it');

-- 4–5: someone else's vehicle, which exists, is still refused, on insert and on update.
select throws_ok($$ select pg_temp.drive('dd200000-0000-0000-0000-000000000003', 'dd100000-0000-0000-0000-0000000000b1') $$,
  '42501', 'vehicle does not belong to the driver', 'a drive in someone else''s vehicle is still refused');
select throws_ok(
  $$ update public.drives set vehicle_id = 'dd100000-0000-0000-0000-0000000000b1' where id = 'dd200000-0000-0000-0000-000000000002' $$,
  '42501', 'vehicle does not belong to the driver', 'a drive can''t be moved to someone else''s vehicle');

-- 6–7: a vehicle hidden from the driver looks deleted to them, so the
-- answer doesn't reveal that it exists, and the drive isn't attached to it.
select lives_ok($$ select pg_temp.drive('dd200000-0000-0000-0000-000000000004', 'dd100000-0000-0000-0000-0000000000b2') $$,
  'a vehicle hidden from the driver is treated as deleted');
select pg_temp.as_admin();
select is((select count(*)::int from public.drives where vehicle_id in
             ('dd100000-0000-0000-0000-0000000000b1', 'dd100000-0000-0000-0000-0000000000b2')),
  0, 'no drive is attached to someone else''s vehicle');

select * from finish();
rollback;
