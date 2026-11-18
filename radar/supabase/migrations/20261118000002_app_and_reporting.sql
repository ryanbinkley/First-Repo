-- Radar app API + read-only reporting layer

-- =====================================================================
-- radar_state(): everything the dashboard needs, in the same JSON shape the
-- single-file dashboard uses today. Runs with the caller's rights, so
-- row-level security applies (non-members get nothing).
-- =====================================================================
create function public.schedule_json(s public.line_schedules) returns jsonb
  language sql immutable as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'freq',   s.freq,
    'amount', s.amount,
    'anchor', case when s.freq = 'biweekly' then s.anchor end,
    'day',    case when s.freq = 'monthly' then case when s.last_week then to_jsonb('last'::text) else to_jsonb(s.day_of_month) end end,
    'months', case when s.freq = 'monthly' then to_jsonb(s.months) end,
    'shift',  nullif(s.shift_weeks, 0)))
$$;

create function public.radar_state() returns jsonb
  language sql stable security invoker set search_path = public as $$
with st as (select * from settings where id = 1),
ln as (select * from forecast_lines where archived_at is null),
lw as (select * from week_closes where week_ending <= (select as_of from st) order by week_ending desc limit 1),
lw_snap as (
  select id from forecast_snapshots
   where as_of = (select week_ending - 7 from lw)
   order by taken_at desc limit 1),
lw_rows as (
  select l.key,
         jsonb_build_object('forecast', coalesce(v.amount, 0), 'actual', a.amount) as row
    from ln l
    left join forecast_snapshot_values v on v.line_id = l.id and v.snapshot_id = (select id from lw_snap)
                                         and v.week_ending = (select week_ending from lw)
    left join weekly_actuals a on a.line_id = l.id and a.week_ending = (select week_ending from lw)
   where v.amount is not null or a.amount is not null)
select jsonb_build_object(
  'company',      st.company,
  'asOf',         st.as_of,
  'startingCash', st.starting_cash,
  'minCash',      st.min_cash,
  'flagMin',      st.flag_min,
  'weeks',        st.weeks,
  'osChecks',     st.os_checks,
  'updatedAt',    coalesce((select max(at) from change_log), st.updated_at),
  'lines', coalesce((
    select jsonb_agg(
             jsonb_strip_nulls(jsonb_build_object(
               'id', l.key, 'name', l.name, 'kind', l.kind, 'note', l.note,
               'rule', coalesce((select schedule_json(s) from line_schedules s where s.line_id = l.id and s.effective_from is null),
                                '{"freq":"none","amount":0}'::jsonb),
               'changes', (select jsonb_agg(jsonb_build_object('from', s.effective_from, 'rule', schedule_json(s)) order by s.effective_from)
                             from line_schedules s where s.line_id = l.id and s.effective_from is not null)))
             order by l.sort_order, l.created_at)
      from ln l), '[]'::jsonb),
  'overrides', coalesce((
    select jsonb_object_agg(k, o) from (
      select l.key as k, jsonb_object_agg(w.week_ending, w.amount) as o
        from week_overrides w join ln l on l.id = w.line_id group by l.key) x), '{}'::jsonb),
  'oneTime', coalesce((
    select jsonb_agg(jsonb_build_object('id', i.id, 'date', i.item_date, 'lineId', l.key,
                                        'description', i.description, 'amount', i.amount) order by i.item_date)
      from one_time_items i join ln l on l.id = i.line_id), '[]'::jsonb),
  'importRules', coalesce((
    select jsonb_agg(jsonb_build_object('id', r.id, 'match', r.match_text, 'dir', r.direction,
                                        'account', coalesce(r.account_last4, ''),
                                        'lineId', case when r.action = 'ignore' then 'ignore' else l.key end)
                     order by r.priority)
      from import_rules r left join forecast_lines l on l.id = r.line_id), '[]'::jsonb),
  'lastWeek', (
    select jsonb_build_object('weekEnding', lw.week_ending, 'startCash', lw.start_cash,
                              'osStart', lw.os_checks_start,
                              'rows', coalesce((select jsonb_object_agg(key, row) from lw_rows), '{}'::jsonb))
      from lw))
from st
$$;

-- =====================================================================
-- Reporting schema: curated, read-only views for Data Studio and the
-- Open WebUI finance assistant. Grant this schema (and nothing else) to
-- the radar_readonly role.
-- =====================================================================
create schema reporting;
comment on schema reporting is 'Read-only views of Radar data for dashboards and the AI assistant.';

create view reporting.forecast_lines as
  select key, name, kind, note, sort_order, archived_at is not null as archived from public.forecast_lines;

create view reporting.line_schedules as
  select l.key as line_key, l.name as line_name, s.effective_from, s.freq, s.amount, s.anchor,
         s.day_of_month, s.last_week, s.months, s.shift_weeks
    from public.line_schedules s join public.forecast_lines l on l.id = s.line_id;

create view reporting.weekly_actuals as
  select a.week_ending, l.key as line_key, l.name as line_name, l.kind, a.amount, a.source
    from public.weekly_actuals a join public.forecast_lines l on l.id = a.line_id;

create view reporting.week_summary as
  select c.week_ending, c.start_cash,
         coalesce(sum(a.amount) filter (where l.kind = 'in'), 0)  as cash_in,
         coalesce(sum(a.amount) filter (where l.kind = 'out'), 0) as cash_out,
         c.os_checks_start, c.os_checks_end,
         c.start_cash + coalesce(sum(a.amount) filter (where l.kind = 'in'), 0)
                      - coalesce(sum(a.amount) filter (where l.kind = 'out'), 0) as end_cash
    from public.week_closes c
    left join public.weekly_actuals a on a.week_ending = c.week_ending
    left join public.forecast_lines l on l.id = a.line_id
   group by c.week_ending;

create view reporting.bank_transactions as
  select t.post_date, t.account_last4, t.account_name, t.amount, t.description, t.detail, t.txn_type,
         l.name as line_name, t.ignored, t.categorized_by, f.file_name
    from public.bank_transactions t
    join public.bank_files f on f.id = t.file_id
    left join public.forecast_lines l on l.id = t.line_id;

-- How good was each forecast? One row per snapshot × line × forecast week that has actuals.
create view reporting.forecast_accuracy as
  select s.as_of as forecast_made_for_week, v.week_ending,
         ((v.week_ending - s.as_of) / 7)::int as weeks_ahead,
         l.key as line_key, l.name as line_name, l.kind,
         v.amount as forecast, coalesce(a.amount, 0) as actual,
         coalesce(a.amount, 0) - v.amount as variance
    from public.forecast_snapshot_values v
    join public.forecast_snapshots s on s.id = v.snapshot_id
    join public.forecast_lines l on l.id = v.line_id
    join public.week_closes c on c.week_ending = v.week_ending
    left join public.weekly_actuals a on a.week_ending = v.week_ending and a.line_id = v.line_id;

create view reporting.change_history as
  select at, user_email, via, table_name, action, row_key, changed from public.change_log;

do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'radar_readonly') then
    create role radar_readonly nologin;   -- the admin turns on login + password when connecting a tool
  end if;
end $$;
grant usage on schema reporting to radar_readonly;
grant select on all tables in schema reporting to radar_readonly;
revoke all on schema reporting from public;
revoke execute on function public.radar_state() from anon;
grant execute on function public.radar_state(), public.schedule_json(public.line_schedules) to authenticated;
