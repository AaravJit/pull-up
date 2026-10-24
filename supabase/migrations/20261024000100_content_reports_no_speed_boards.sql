-- Reports about posts, comments, meets and profiles keep a server-side copy
-- of what was reported, and speed boards are closed.
--
-- report_user only snapshots direct messages. Reports from the feed, a
-- meet or a profile carried an excerpt the reporter's app wrote into
-- `details`, which staff couldn't trust, and the content itself was gone
-- once its author deleted it. report_content looks the content up as the
-- reporter may see it, files the report through report_user (same daily
-- limit, same moderation notification) and stores the copy in `snapshot`.
--
-- The app no longer shows closed-course (speed) boards: Pull Up doesn't rank
-- speed. leaderboard() only lists people with performance_leaderboard_opt_in,
-- so keeping it off closes those boards on the server too.

create or replace function public.report_content(p_kind text, p_id uuid, p_reason text, p_details text default '')
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  subject uuid;
  snap jsonb;
  report_id uuid;
begin
  if p_kind = 'post' then
    select p.author_id,
           jsonb_build_object('caption', p.caption, 'kind', p.kind, 'visibility', p.visibility, 'created_at', p.created_at,
                              'media', (select coalesce(jsonb_agg(pm.storage_path order by pm.position), '[]'::jsonb)
                                        from public.post_media pm where pm.post_id = p.id))
      into subject, snap
    from public.posts p
    where p.id = p_id and public.can_view_post(p.id);
  elsif p_kind = 'comment' then
    select c.author_id, jsonb_build_object('body', c.body, 'post_id', c.post_id, 'created_at', c.created_at)
      into subject, snap
    from public.comments c
    where c.id = p_id and public.can_view_post(c.post_id) and not public.is_blocked_between(c.author_id, me);
  elsif p_kind = 'meet' then
    select m.host_id,
           jsonb_build_object('title', m.title, 'details', m.details, 'venue_name', m.venue_name,
                              'starts_at', m.starts_at, 'created_at', m.created_at)
      into subject, snap
    from public.meets m
    where m.id = p_id and public.can_view_meet(m.id);
  elsif p_kind = 'profile' then
    select p.id,
           jsonb_build_object('username', p.username, 'display_name', p.display_name, 'avatar_path', p.avatar_path,
                              'bio', case when public.can_view(p.id, p.visibility) then d.bio end)
      into subject, snap
    from public.profiles p
    left join public.profile_details d on d.user_id = p.id
    where p.id = p_id and not public.is_blocked_between(p.id, me);
  end if;
  if subject is null then
    raise exception 'can''t report this' using errcode = '42501';
  end if;
  report_id := public.report_user(subject, p_reason, p_details, null);
  update public.reports
     set snapshot = snap || jsonb_build_object('content_kind', p_kind, 'content_id', p_id)
   where id = report_id;
  return report_id;
end;
$$;

revoke execute on function public.report_content(text, uuid, text, text) from public, anon;
grant execute on function public.report_content(text, uuid, text, text) to authenticated;

-- Nobody has opted in on any project (staging has no accounts and there is
-- no production project yet), so the constraint goes on directly. If a row
-- did have the opt-in, this fails instead of changing someone's settings.
alter table public.privacy_settings
  add constraint privacy_settings_no_performance_boards check (not performance_leaderboard_opt_in);
