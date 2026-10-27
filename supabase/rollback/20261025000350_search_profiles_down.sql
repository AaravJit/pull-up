-- Reverts 20261025000350_search_profiles.sql. No data is touched; builds
-- that call the RPC fall back to failing searches until re-applied.

drop function if exists public.search_profiles(text);
