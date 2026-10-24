-- Reverts 20261024000100_content_reports_no_speed_boards.sql. Reports already
-- filed keep their snapshots.
alter table public.privacy_settings drop constraint if exists privacy_settings_no_performance_boards;
drop function if exists public.report_content(text, uuid, text, text);
