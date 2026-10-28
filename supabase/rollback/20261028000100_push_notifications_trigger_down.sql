-- Reverts 20261028000100_push_notifications_trigger.sql. No data is touched;
-- new notifications stop being pushed until it is re-applied (or a dashboard
-- webhook is added instead).

drop trigger if exists notifications_push on public.notifications;
drop function if exists private.queue_push();
