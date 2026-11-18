-- Radar's machine forecast: history for the evidence engine, and a record of suggestions people set aside.

-- Everything the evidence engine needs, in one compact call (members only):
--   actuals:   [[week, line_key, amount], ...] since p_since
--   snapshots: [{asOf, rows: [[week, line_key, amount], ...]}] for forecasts made since p_snap_since
--              (one per week: the latest one saved for that week)
--   lines:     every line, including history-only ones, with its kind and category
create function public.history_bundle(p_since date, p_snap_since date) returns jsonb
  language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  if not public.is_member() then raise exception 'Members only' using errcode = '42501'; end if;
  with snaps as (
    select distinct on (as_of) id, as_of from forecast_snapshots where as_of >= p_snap_since order by as_of, taken_at desc
  )
  select jsonb_build_object(
    'actuals', coalesce((select jsonb_agg(jsonb_build_array(a.week_ending, l.key, a.amount) order by a.week_ending)
                           from weekly_actuals a join forecast_lines l on l.id = a.line_id where a.week_ending >= p_since), '[]'),
    'snapshots', coalesce((select jsonb_agg(jsonb_build_object('asOf', s.as_of, 'rows',
                             (select coalesce(jsonb_agg(jsonb_build_array(v.week_ending, l.key, v.amount)), '[]')
                                from forecast_snapshot_values v join forecast_lines l on l.id = v.line_id where v.snapshot_id = s.id)) order by s.as_of)
                           from snaps s), '[]'),
    'lines', coalesce((select jsonb_agg(jsonb_build_object('key', key, 'name', name, 'kind', kind, 'category', category)) from forecast_lines), '[]'),
    'feedback', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'suggestion', suggestion_id, 'reason', reason, 'until', until,
                             'by', created_by_email, 'at', created_at) order by created_at)
                           from suggestion_feedback where until >= current_date), '[]'))
  into v;
  return v;
end $$;

-- "Not now" on a suggestion: hidden until the date given, with the reason kept for future analysis.
create table public.suggestion_feedback (
  id                uuid primary key default gen_random_uuid(),
  suggestion_id     text not null,                 -- e.g. 'payroll:calibrate'
  reason            text not null default '',
  until             date not null,
  created_by        uuid not null default auth.uid(),
  created_by_email  text not null default coalesce(auth.jwt() ->> 'email', ''),
  created_at        timestamptz not null default now()
);
alter table public.suggestion_feedback enable row level security;
create policy read on public.suggestion_feedback for select to authenticated using (public.is_member());
create policy add on public.suggestion_feedback for insert to authenticated with check (public.can_edit() and created_by = auth.uid());
create policy remove on public.suggestion_feedback for delete to authenticated using (public.can_edit());
grant select, insert, delete on public.suggestion_feedback to authenticated;
create trigger audit after insert or delete on public.suggestion_feedback
  for each row execute function public.log_change('id', 'suggestion_id');

revoke execute on function public.history_bundle(date, date) from public, anon;
grant execute on function public.history_bundle(date, date) to authenticated;
