-- Text filter (20261025000300): blocked terms are refused on every
-- user-written surface, through direct table writes and RPCs alike, with
-- SQLSTATE PUM01. Made-up tokens stand in for real terms.

begin;
create extension if not exists pgtap with schema extensions;
select plan(41);

insert into auth.users (id, email, raw_user_meta_data) values
  ('f3000000-0000-0000-0000-00000000000a'::uuid, 'tf-ann@example.com', '{"username":"tf_ann"}'),
  ('f3000000-0000-0000-0000-00000000000b'::uuid, 'tf-ben@example.com', '{"username":"tf_ben"}');

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

-- An empty list blocks nothing.
select is(private.moderation_match('zzbadword'), null, 'with no terms nothing is blocked');

insert into private.moderation_terms (term, match, category) values
  ('zzbadword', 'word', 'slur'), ('qqslur', 'contains', 'slur'), ('kill yourself', 'word', 'threat');

-- Matching
select is(private.moderation_match('you ZZBÁDWORD!'), 'zzbadword', 'case, accents and trailing punctuation are folded');
select is(private.moderation_match('z z b a d w o r d'), 'zzbadword', 'spelled-out letters are joined');
select is(private.moderation_match('zzb4dw0rd'), 'zzbadword', 'digit swaps are folded');
select is(private.moderation_match('ｚｚｂａｄｗｏｒｄ'), 'zzbadword', 'fullwidth letters are folded');
select is(private.moderation_match('zzbaaadwooord'), 'zzbadword', 'stretched letters are collapsed');
select is(private.moderation_match('zzbadwordy'), null, 'word terms need whole words');
select is(private.moderation_match('bigqqslurguy'), 'qqslur', 'contains terms match inside words');
select is(private.moderation_match('just k1ll   y0urself'), 'kill yourself', 'phrases match across spacing');
select is(private.moderation_match('a normal caption about my car'), null, 'ordinary text passes');

insert into public.vehicles (id, owner_id, kind, make, model, year, visibility) values
  ('f3100000-0000-0000-0000-000000000001', 'f3000000-0000-0000-0000-00000000000a', 'car', 'Mazda', 'MX-5', 1990, 'public');
insert into public.posts (id, author_id, caption, visibility) values
  ('f3200000-0000-0000-0000-000000000001', 'f3000000-0000-0000-0000-00000000000a', 'Clean caption', 'public');

select pg_temp.act_as('f3000000-0000-0000-0000-00000000000a');

-- Profiles
select throws_ok($$ update public.profiles set display_name = 'The zzbadword' where id = auth.uid() $$, 'PUM01', null, 'display name');
select throws_ok($$ update public.profile_details set bio = 'qqslur fan' where user_id = auth.uid() $$, 'PUM01', null, 'bio');
select is(public.username_status('zzbadword_99'), 'reserved', 'a username with a term reads as reserved');
select throws_ok($$ select public.claim_username('the.zzbadword', 'Ann') $$, '22023', 'username reserved', 'claim_username refuses it');
select throws_ok($$ update public.profiles set username = 'zzbadword' where id = auth.uid() $$, '22023', null, 'a direct username update refuses it');
select throws_ok($$ select public.claim_username('tf_ann2', 'zzbadword') $$, 'PUM01', null, 'claim_username checks the display name');
select lives_ok($$ update public.profiles set display_name = 'Ann' where id = auth.uid() $$, 'a clean display name is saved');

-- Garage
select throws_ok($$ insert into public.vehicles (owner_id, kind, make, model, year) values (auth.uid(), 'car', 'Zzbadword', 'X', 2020) $$, 'PUM01', null, 'vehicle make');
select throws_ok($$ update public.vehicles set nickname = 'qqslurmobile' where id = 'f3100000-0000-0000-0000-000000000001' $$, 'PUM01', null, 'vehicle nickname');
select throws_ok($$ update public.vehicles set summary = 'kill yourself' where id = 'f3100000-0000-0000-0000-000000000001' $$, 'PUM01', null, 'vehicle description');
select throws_ok($$ update public.vehicles set trim = 'zzbadword' where id = 'f3100000-0000-0000-0000-000000000001' $$, 'PUM01', null, 'vehicle trim');
select throws_ok($$ insert into public.vehicle_mods (vehicle_id, title) values ('f3100000-0000-0000-0000-000000000001', 'zzbadword intake') $$, 'PUM01', null, 'mod title');
select throws_ok($$ insert into public.vehicle_mods (vehicle_id, title, brand, notes) values ('f3100000-0000-0000-0000-000000000001', 'Intake', 'Acme', 'qqslur') $$, 'PUM01', null, 'mod notes');

-- Feed
select throws_ok($$ insert into public.posts (author_id, caption) values (auth.uid(), 'look at this zzbadword') $$, 'PUM01', 'This contains words that Pull Up''s community guidelines don''t allow. Edit it and try again.', 'post caption, with the message the app shows');
select throws_ok($$ update public.posts set caption = 'zzbadword' where id = 'f3200000-0000-0000-0000-000000000001' $$, 'PUM01', null, 'editing a caption');
select throws_ok($$ insert into public.comments (post_id, author_id, body) values ('f3200000-0000-0000-0000-000000000001', auth.uid(), 'k i l l yourself') $$, 'PUM01', null, 'comment');

-- Meets
select throws_ok($$ insert into public.meets (host_id, title, starts_at, ends_at, venue_name, lat, lon) values (auth.uid(), 'Zzbadword night', now() + interval '1 day', now() + interval '1 day 2 hours', 'Lot', 1, 1) $$, 'PUM01', null, 'meet title');
select throws_ok($$ insert into public.meets (host_id, title, details, starts_at, ends_at, venue_name, lat, lon) values (auth.uid(), 'Cars and coffee', 'qqslur', now() + interval '1 day', now() + interval '1 day 2 hours', 'Lot', 1, 1) $$, 'PUM01', null, 'meet description');
select throws_ok($$ insert into public.meets (host_id, title, starts_at, ends_at, venue_name, lat, lon) values (auth.uid(), 'Cars and coffee', now() + interval '1 day', now() + interval '1 day 2 hours', 'Zzbadword Lot', 1, 1) $$, 'PUM01', null, 'meet venue');
select throws_ok($$ insert into public.meets (host_id, title, address, starts_at, ends_at, venue_name, lat, lon) values (auth.uid(), 'Cars and coffee', '1 Zzbadword St', now() + interval '1 day', now() + interval '1 day 2 hours', 'Lot', 1, 1) $$, 'PUM01', null, 'meet address');

-- Messages
create temp table conv on commit drop as select public.start_conversation('f3000000-0000-0000-0000-00000000000b') as id;
select throws_ok($$ insert into public.messages (conversation_id, sender_id, body) select id, auth.uid(), 'zzbadword' from conv $$, 'PUM01', null, 'direct message');
select lives_ok($$ insert into public.messages (conversation_id, sender_id, body) select id, auth.uid(), 'See you at the meet' from conv $$, 'a clean message is sent');

-- Drives: the offline queue keeps the drive and drops a blocked title; a rename is refused.
insert into public.drives (id, owner_id, vehicle_id, title, started_at, ended_at, distance_m, moving_s, stopped_s, elapsed_s, top_speed_mps)
values ('f3300000-0000-0000-0000-000000000001', auth.uid(), 'f3100000-0000-0000-0000-000000000001', 'zzbadword run',
        now() - interval '2 hours', now() - interval '2 hours' + interval '299 seconds', 898, 299, 0, 299, 3);
select is((select title from public.drives where id = 'f3300000-0000-0000-0000-000000000001'), '', 'a new drive keeps its data and loses the blocked title');
select throws_ok($$ update public.drives set title = 'zzbadword' where id = 'f3300000-0000-0000-0000-000000000001' $$, 'PUM01', null, 'renaming a drive');

-- Adding a term never locks rows written before it.
select pg_temp.as_admin();
insert into private.moderation_terms (term) values ('caption');
select pg_temp.act_as('f3000000-0000-0000-0000-00000000000a');
select lives_ok($$ update public.posts set visibility = 'friends' where id = 'f3200000-0000-0000-0000-000000000001' $$, 'other columns of an older row can still change');

-- The server and the SQL editor are filtered too (no bypass through owner-rights code).
select pg_temp.as_admin();
select throws_ok($$ insert into public.comments (post_id, author_id, body) values ('f3200000-0000-0000-0000-000000000001', 'f3000000-0000-0000-0000-00000000000b', 'zzbadword') $$, 'PUM01', null, 'the filter applies to every role');

-- Sign-up never fails over a name.
insert into auth.users (id, email, raw_user_meta_data) values
  ('f3000000-0000-0000-0000-00000000000c'::uuid, 'tf-cat@example.com', '{"username":"zzbadword","display_name":"qqslur"}');
select matches((select username from public.profiles where id = 'f3000000-0000-0000-0000-00000000000c'), '^driver_', 'a blocked requested username becomes the placeholder');
select is((select display_name from public.profiles where id = 'f3000000-0000-0000-0000-00000000000c'), '', 'a blocked display name is left empty');

-- Clients can't see or change the list.
select pg_temp.act_as('f3000000-0000-0000-0000-00000000000a');
select throws_ok($$ select * from private.moderation_terms $$, '42501', null, 'signed-in users can''t read the term list');
select throws_ok($$ delete from private.moderation_terms $$, '42501', null, 'or change it');
select throws_ok($$ select private.moderation_match('x') $$, '42501', null, 'or probe the matcher');

select * from finish();
rollback;
