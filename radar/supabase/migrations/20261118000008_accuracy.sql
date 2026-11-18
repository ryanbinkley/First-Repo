-- Forecast accuracy summary for the Radar "Forecast accuracy" tab (members only).
-- Compares every saved forecast (live and historical snapshots) with the actuals of the weeks it predicted.
create function public.accuracy_report(p_since date) returns jsonb
  language plpgsql stable security definer set search_path = public as $$
declare v_result jsonb;
begin
  if not public.is_member() then raise exception 'Members only' using errcode = '42501'; end if;

  with snap as (
    select id, as_of, starting_cash from forecast_snapshots where as_of >= p_since - 91
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
revoke execute on function public.accuracy_report(date) from public, anon;
grant execute on function public.accuracy_report(date) to authenticated;
