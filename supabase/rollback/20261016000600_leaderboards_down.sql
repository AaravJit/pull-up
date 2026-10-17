-- Reverts 20261016000600_leaderboards.sql (function only; no data).
drop function if exists public.leaderboard(text, text, text, public.vehicle_kind, integer);
