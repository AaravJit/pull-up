-- Reverts 20261025000400_terms_acceptance_minimum_age.sql. Removes the
-- enforcement first, then the API, then the records (acceptances and age
-- check outcomes are lost). Privacy settings changed by a failing age check
-- stay as they are.

drop policy if exists "Storage: uploads need the age check and terms" on storage.objects;
drop policy if exists "Storage: replacing files needs the age check and terms" on storage.objects;

drop trigger if exists profiles_consent_required on public.profiles;
drop trigger if exists profile_details_consent_required on public.profile_details;
drop trigger if exists vehicles_consent_required on public.vehicles;
drop trigger if exists vehicle_mods_consent_required on public.vehicle_mods;
drop trigger if exists vehicle_photos_consent_required on public.vehicle_photos;
drop trigger if exists posts_consent_required on public.posts;
drop trigger if exists post_media_consent_required on public.post_media;
drop trigger if exists likes_consent_required on public.likes;
drop trigger if exists comments_consent_required on public.comments;
drop trigger if exists meets_consent_required on public.meets;
drop trigger if exists meet_rsvps_consent_required on public.meet_rsvps;
drop trigger if exists follows_consent_required on public.follows;
drop trigger if exists conversations_consent_required on public.conversations;
drop trigger if exists messages_consent_required on public.messages;
drop trigger if exists message_reactions_consent_required on public.message_reactions;
drop trigger if exists drive_shared_routes_consent_required on public.drive_shared_routes;

drop function if exists public.record_age_check(boolean);
drop function if exists public.accept_terms(text);
drop function if exists public.my_consent_status();
drop function if exists public.my_consent_ok();
drop function if exists private.enforce_consent();
drop function if exists private.consent_message(text);
drop function if exists private.consent_problem(uuid);

drop table if exists private.age_checks;
drop function if exists private.minimum_age();
drop table if exists public.terms_acceptances;
drop function if exists private.stamp_terms_acceptance();
drop table if exists public.terms_versions;
