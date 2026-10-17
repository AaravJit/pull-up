-- Reverts 20261018000200_function_rate_limits.sql. Deploy a
-- verify-subscription without the rate limit first, or it answers 500.
-- Only the rate-limit log (at most an hour of call times) is lost.

drop function if exists public.take_function_slot(uuid, text, integer, integer);
drop table if exists private.function_calls;
