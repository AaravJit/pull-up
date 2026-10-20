-- Reverts 20261018000700_explicit_api_grants.sql on purpose only partly.
--
-- Taking the grants away would lock every client and Edge Function out of
-- the database on projects without the old default privileges, and on the
-- local stack the old default gave the same grants anyway. So nothing is
-- revoked here; the revokes the migration repeated are still in force.
select 1;
