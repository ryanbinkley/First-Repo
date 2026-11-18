-- Radar's own forecast: saved runs (for the Open WebUI assistant), weekly frozen machine forecasts
-- (for the scoreboard), and a record of applied suggestions.

alter table public.forecast_snapshots add column kind text not null default 'plan' check (kind in ('plan', 'machine'));
create index on public.forecast_snapshots (kind, as_of);

alter table public.suggestion_feedback add column action text not null default 'dismissed' check (action in ('dismissed', 'applied'));

-- Every distinct state of Radar's view (saved by the app when it changes). Append-only.
create table public.machine_runs (
  id              uuid primary key default gen_random_uuid(),
  as_of           date not null,
  engine_version  text not null,
  suggestions     jsonb not null,     -- [{id, name, method, confidence, cashEffect, dismissed, reasons[], weekly{week: change}}]
  cols            jsonb not null,     -- [{week, plan, radar}] ending cash
  facts           jsonb not null default '[]',
  created_by      uuid not null default auth.uid(),
  created_at      timestamptz not null default now()
);
create index on public.machine_runs (as_of, created_at desc);
alter table public.machine_runs enable row level security;
create policy read on public.machine_runs for select to authenticated using (public.is_member());
create policy add on public.machine_runs for insert to authenticated with check (public.can_edit() and created_by = auth.uid());
grant select, insert on public.machine_runs to authenticated;
create trigger machine_runs_append_only before update or delete on public.machine_runs for each row execute function public.forbid_change();

-- "last week's forecast" and the evidence engine always use people's plan, never Radar's own forecast
create or replace function public.radar_state() returns jsonb
  language sql stable security invoker set search_path = public as $$
with st as (select * from settings where id = 1),
ln as (select * from forecast_lines where archived_at is null),
lw as (select * from week_closes where week_ending <= (select as_of from st) order by week_ending desc limit 1),
lw_snap as (
  select id from forecast_snapshots
   where as_of = (select week_ending - 7 from lw) and kind = 'plan'
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

create or replace function public.save_radar(p_ops jsonb) returns jsonb
  language plpgsql security invoker set search_path = public as $$
declare
  op jsonb; r jsonb; v_line uuid; v_snap uuid; n int := 0;
begin
  if not public.can_edit() then
    raise exception 'Only Radar editors can make changes' using errcode = '42501';
  end if;
  perform public.set_via('radar');

  for op in select value from jsonb_array_elements(p_ops) loop
    n := n + 1;
    case op ->> 't'
    when 'settings' then
      insert into settings (id, company, as_of, starting_cash, min_cash, flag_min, os_checks, weeks)
      values (1, coalesce(op ->> 'company', ''), (op ->> 'asOf')::date, (op ->> 'startingCash')::numeric,
              coalesce((op ->> 'minCash')::numeric, 150000), coalesce((op ->> 'flagMin')::numeric, 10000),
              coalesce((op ->> 'osChecks')::numeric, 0), coalesce((op ->> 'weeks')::smallint, 13))
      on conflict (id) do update set company = excluded.company, as_of = excluded.as_of,
        starting_cash = excluded.starting_cash, min_cash = excluded.min_cash, flag_min = excluded.flag_min,
        os_checks = excluded.os_checks, weeks = excluded.weeks;

    when 'line' then
      insert into forecast_lines (key, name, kind, sort_order, note)
      values (op ->> 'key', op ->> 'name', op ->> 'kind', coalesce((op ->> 'sort')::int, 0), coalesce(op ->> 'note', ''))
      on conflict (key) do update set name = excluded.name, kind = excluded.kind,
        sort_order = excluded.sort_order, note = excluded.note, archived_at = null;

    when 'line_archive' then  -- lines are archived, never deleted, so history keeps its labels
      update forecast_lines set archived_at = now() where key = op ->> 'key';

    when 'schedule' then
      v_line := line_id_of(op ->> 'key'); r := op -> 'rule';
      insert into line_schedules (line_id, effective_from, freq, amount, anchor, day_of_month, last_week, months, shift_weeks)
      values (v_line, (op ->> 'from')::date, r ->> 'freq', coalesce((r ->> 'amount')::numeric, 0),
              case when r ->> 'freq' = 'biweekly' then (r ->> 'anchor')::date end,
              case when r ->> 'freq' = 'monthly' and r ->> 'day' <> 'last' then (r ->> 'day')::smallint end,
              r ->> 'freq' = 'monthly' and r ->> 'day' = 'last',
              coalesce((select array_agg(x::smallint) from jsonb_array_elements_text(r -> 'months') x), '{}'),
              coalesce((r ->> 'shift')::smallint, 0))
      on conflict on constraint line_schedules_line_id_effective_from_key do update set
        freq = excluded.freq, amount = excluded.amount, anchor = excluded.anchor, day_of_month = excluded.day_of_month,
        last_week = excluded.last_week, months = excluded.months, shift_weeks = excluded.shift_weeks;

    when 'schedule_delete' then
      delete from line_schedules where line_id = line_id_of(op ->> 'key')
        and effective_from is not distinct from (op ->> 'from')::date;

    when 'override' then
      insert into week_overrides (line_id, week_ending, amount)
      values (line_id_of(op ->> 'key'), (op ->> 'week')::date, (op ->> 'amount')::numeric)
      on conflict (line_id, week_ending) do update set amount = excluded.amount;

    when 'override_delete' then
      delete from week_overrides where line_id = line_id_of(op ->> 'key') and week_ending = (op ->> 'week')::date;

    when 'one' then
      insert into one_time_items (id, line_id, item_date, description, amount)
      values ((op ->> 'id')::uuid, line_id_of(op ->> 'key'), (op ->> 'date')::date,
              coalesce(op ->> 'description', ''), (op ->> 'amount')::numeric)
      on conflict (id) do update set line_id = excluded.line_id, item_date = excluded.item_date,
        description = excluded.description, amount = excluded.amount;

    when 'one_delete' then
      delete from one_time_items where id = (op ->> 'id')::uuid;

    when 'rule' then
      insert into import_rules (id, priority, match_text, direction, account_last4, action, line_id)
      values ((op ->> 'id')::uuid, (op ->> 'priority')::int, coalesce(op ->> 'match', ''), coalesce(op ->> 'dir', 'any'),
              nullif(op ->> 'account', ''),
              case when op ->> 'line' = 'ignore' then 'ignore' else 'categorize' end,
              case when op ->> 'line' in ('ignore', '') or op ->> 'line' is null then null else line_id_of(op ->> 'line') end)
      on conflict (id) do update set priority = excluded.priority, match_text = excluded.match_text,
        direction = excluded.direction, account_last4 = excluded.account_last4, action = excluded.action,
        line_id = excluded.line_id;

    when 'rule_delete' then
      delete from import_rules where id = (op ->> 'id')::uuid;

    when 'week' then
      insert into week_closes (week_ending, start_cash, os_checks_start, os_checks_end)
      values ((op ->> 'week')::date, (op ->> 'startCash')::numeric,
              coalesce((op ->> 'osStart')::numeric, 0), coalesce((op ->> 'osEnd')::numeric, 0))
      on conflict (week_ending) do update set start_cash = excluded.start_cash,
        os_checks_start = excluded.os_checks_start, os_checks_end = excluded.os_checks_end;

    when 'actual' then
      insert into weekly_actuals (week_ending, line_id, amount, source)
      values ((op ->> 'week')::date, line_id_of(op ->> 'key'), (op ->> 'amount')::numeric, coalesce(op ->> 'source', 'manual'))
      on conflict (week_ending, line_id) do update set amount = excluded.amount, source = excluded.source;

    when 'actual_delete' then
      delete from weekly_actuals where week_ending = (op ->> 'week')::date and line_id = line_id_of(op ->> 'key');

    when 'snapshot' then
      insert into forecast_snapshots (as_of, starting_cash, reason, kind)
      values ((op ->> 'asOf')::date, (op ->> 'startingCash')::numeric, coalesce(op ->> 'reason', 'weekly roll-forward'), coalesce(op ->> 'kind', 'plan'))
      returning id into v_snap;
      insert into forecast_snapshot_values (snapshot_id, line_id, week_ending, amount)
      select v_snap, line_id_of(v ->> 'key'), (v ->> 'week')::date, (v ->> 'amount')::numeric
        from jsonb_array_elements(op -> 'values') v;

    else
      raise exception 'Unknown change type "%"', op ->> 't';
    end case;
  end loop;

  return jsonb_build_object('applied', n, 'updatedAt', (select max(at) from change_log));
end $$;

drop function public.accuracy_report(date);
create function public.accuracy_report(p_since date, p_kind text default 'plan') returns jsonb
  language plpgsql stable security definer set search_path = public as $$
declare v_result jsonb;
begin
  if not public.is_member() then raise exception 'Members only' using errcode = '42501'; end if;

  with snap as (
    select id, as_of, starting_cash from forecast_snapshots where as_of >= p_since - 91 and kind = p_kind
  ),
  fv as (   -- forecast per snapshot and week
    select s.id, s.as_of, v.week_ending,
           sum(v.amount) filter (where l.kind = 'in')  as f_in,
           sum(v.amount) filter (where l.kind = 'out') as f_out
      from snap s join forecast_snapshot_values v on v.snapshot_id = s.id join forecast_lines l on l.id = v.line_id
     group by 1, 2, 3
  ),
  fe as (   -- forecast ending cash = starting cash + cumulative forecast net
    select fv.*, ((fv.week_ending - fv.as_of) / 7)::int as h,
           s.starting_cash + sum(coalesce(f_in, 0) - coalesce(f_out, 0)) over (partition by fv.id order by fv.week_ending) as f_end
      from fv join snap s on s.id = fv.id
  ),
  act as (
    select c.week_ending, c.start_cash,
           coalesce(sum(a.amount) filter (where l.kind = 'in'), 0)  as a_in,
           coalesce(sum(a.amount) filter (where l.kind = 'out'), 0) as a_out
      from week_closes c join weekly_actuals a on a.week_ending = c.week_ending join forecast_lines l on l.id = a.line_id
     group by 1, 2
  ),
  pairs as (
    select fe.h, fe.week_ending, a.a_in - coalesce(fe.f_in, 0) as d_in, a.a_out - coalesce(fe.f_out, 0) as d_out,
           (a.start_cash + a.a_in - a.a_out) - fe.f_end as d_end
      from fe join act a on a.week_ending = fe.week_ending
     where fe.week_ending >= p_since and fe.h between 1 and 13
  ),
  by_h as (
    select h, count(*) as n, round(avg(d_in)) as bias_in, round(avg(d_out)) as bias_out, round(avg(d_end)) as bias_end,
           round(percentile_cont(0.5) within group (order by abs(d_end))::numeric) as miss_end,
           round(percentile_cont(0.8) within group (order by abs(d_end))::numeric) as miss_end_80
      from pairs group by h
  ),
  by_year as (
    select extract(year from week_ending)::int as year, count(*) as n, round(avg(d_end)) as bias_end,
           round(percentile_cont(0.5) within group (order by abs(d_end))::numeric) as miss_end
      from pairs where h = 4 group by 1
  ),
  line_pairs as (   -- line level, 1-4 weeks ahead
    select l.key, l.name, l.kind, l.category, l.archived_at is not null as archived,
           v.amount as f, coalesce(a.amount, 0) as a
      from snap s
      join forecast_snapshot_values v on v.snapshot_id = s.id
      join forecast_lines l on l.id = v.line_id
      join act w on w.week_ending = v.week_ending
      left join weekly_actuals a on a.week_ending = v.week_ending and a.line_id = v.line_id
     where v.week_ending >= p_since and (v.week_ending - s.as_of) between 7 and 28
  ),
  by_line as (
    select key, name, kind, category, archived, count(*) as n, round(avg(f)) as avg_f, round(avg(a)) as avg_a,
           round(avg(a - f)) as bias, round(avg(abs(a - f))) as mae
      from line_pairs group by 1, 2, 3, 4, 5
     having avg(abs(f)) + avg(abs(a)) >= 500
  )
  select jsonb_build_object(
    'since', p_since,
    'weeks', (select count(distinct week_ending) from pairs),
    'forecasts', (select count(*) from snap where as_of >= p_since - 91),
    'horizon', coalesce((select jsonb_agg(to_jsonb(b) order by h) from by_h b), '[]'),
    'years', coalesce((select jsonb_agg(to_jsonb(y) order by year) from by_year y), '[]'),
    'lines', coalesce((select jsonb_agg(to_jsonb(x) order by abs(bias) desc) from by_line x), '[]'))
  into v_result;
  return v_result;
end $$;

create or replace function public.history_bundle(p_since date, p_snap_since date) returns jsonb
  language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  if not public.is_member() then raise exception 'Members only' using errcode = '42501'; end if;
  with snaps as (
    select distinct on (as_of) id, as_of from forecast_snapshots where as_of >= p_snap_since and kind = 'plan' order by as_of, taken_at desc
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
                           from suggestion_feedback where action = 'dismissed' and until >= current_date), '[]'))
  into v;
  return v;
end $$;

-- Scoreboard: the plan vs Radar, compared on exactly the same forecast weeks
create function public.scoreboard(p_since date) returns jsonb
  language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  if not public.is_member() then raise exception 'Members only' using errcode = '42501'; end if;
  with snap as (
    select distinct on (as_of, kind) id, as_of, kind, starting_cash from forecast_snapshots
     where as_of >= p_since - 91 order by as_of, kind, taken_at desc
  ),
  paired as (select as_of from snap group by as_of having count(distinct kind) = 2),
  fv as (
    select s.kind, s.as_of, v.week_ending, s.starting_cash,
           sum(case when l.kind = 'in' then v.amount else -v.amount end) as net
      from snap s join paired p on p.as_of = s.as_of
      join forecast_snapshot_values v on v.snapshot_id = s.id join forecast_lines l on l.id = v.line_id
     group by 1, 2, 3, 4
  ),
  fe as (select kind, as_of, week_ending, ((week_ending - as_of) / 7)::int as h,
                starting_cash + sum(net) over (partition by kind, as_of order by week_ending) as f_end from fv),
  act as (
    select c.week_ending, c.start_cash + sum(case when l.kind = 'in' then a.amount else -a.amount end) as a_end
      from week_closes c join weekly_actuals a on a.week_ending = c.week_ending join forecast_lines l on l.id = a.line_id group by c.week_ending, c.start_cash
  ),
  e as (select fe.kind, fe.h, abs(act.a_end - fe.f_end) as miss, act.a_end - fe.f_end as lean
          from fe join act on act.week_ending = fe.week_ending where fe.week_ending >= p_since and fe.h between 1 and 13)
  select jsonb_build_object(
    'firstMachine', (select min(as_of) from forecast_snapshots where kind = 'machine'),
    'horizon', coalesce((select jsonb_agg(jsonb_build_object('h', h, 'n', n, 'plan', plan, 'radar', radar, 'planLean', pl, 'radarLean', rl) order by h) from (
       select h, count(*) filter (where kind = 'plan') as n,
              round((percentile_cont(0.5) within group (order by miss) filter (where kind = 'plan'))::numeric) as plan,
              round((percentile_cont(0.5) within group (order by miss) filter (where kind = 'machine'))::numeric) as radar,
              round(avg(lean) filter (where kind = 'plan')) as pl, round(avg(lean) filter (where kind = 'machine')) as rl
         from e group by h) x), '[]'),
    'applied', (select count(*) from suggestion_feedback where action = 'applied' and created_at >= p_since),
    'dismissed', (select count(*) from suggestion_feedback where action = 'dismissed' and created_at >= p_since))
  into v;
  return v;
end $$;
revoke execute on function public.scoreboard(date), public.accuracy_report(date, text) from public, anon;
grant execute on function public.scoreboard(date), public.accuracy_report(date, text) to authenticated;

-- For the Open WebUI assistant (read-only reporting role)
create view reporting.machine_latest as
  select distinct on (as_of) as_of, created_at, engine_version, suggestions, cols, facts
    from public.machine_runs order by as_of, created_at desc;
create view reporting.suggestion_history as
  select suggestion_id, action, reason, until, created_by_email, created_at from public.suggestion_feedback;
create or replace view reporting.forecast_accuracy as
  select s.as_of as forecast_made_for_week, v.week_ending,
         ((v.week_ending - s.as_of) / 7)::int as weeks_ahead,
         l.key as line_key, l.name as line_name, l.kind,
         v.amount as forecast, coalesce(a.amount, 0) as actual,
         coalesce(a.amount, 0) - v.amount as variance,
         l.category, s.source_sha256 is not null as from_history, s.kind as forecast_kind
    from public.forecast_snapshot_values v
    join public.forecast_snapshots s on s.id = v.snapshot_id
    join public.forecast_lines l on l.id = v.line_id
    join public.week_closes c on c.week_ending = v.week_ending
    left join public.weekly_actuals a on a.week_ending = v.week_ending and a.line_id = v.line_id
   where exists (select 1 from public.weekly_actuals x where x.week_ending = v.week_ending);
grant select on reporting.machine_latest, reporting.suggestion_history, reporting.forecast_accuracy to radar_readonly;
