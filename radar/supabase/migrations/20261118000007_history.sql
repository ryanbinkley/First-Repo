-- Historical data: weekly actuals and forecast snapshots recovered from past forecast workbooks,
-- plus the weekly totals/notes the workbooks kept on their "Historical Data" tab.

-- What kind of line this is, so analysis can treat them differently:
--   flow     = recurring business cash flows that history can help predict
--   decision = amounts management chooses (tax payments, owner distributions)
--   transfer = one-offs / transfers that aren't operating cash flow
alter table public.forecast_lines add column category text not null default 'flow'
  check (category in ('flow', 'decision', 'transfer'));
update public.forecast_lines set category = 'decision' where key in ('est_tax', 'owners');

alter table public.weekly_actuals drop constraint weekly_actuals_source_check;
alter table public.weekly_actuals add constraint weekly_actuals_source_check check (source in ('import', 'manual', 'history'));

alter table public.forecast_snapshots add column source_sha256 text;
create unique index forecast_snapshots_source_sha256 on public.forecast_snapshots (source_sha256) where source_sha256 is not null;

-- One row per historical week: which workbook it came from and whether it passed the checks.
create table public.history_sources (
  week_ending        date primary key,
  file_name          text not null,
  sha256             text not null,
  era                text not null,
  actuals_included   boolean not null,
  forecast_included  boolean not null,
  issues             jsonb not null default '[]',
  loaded_by          uuid default auth.uid(),
  loaded_at          timestamptz not null default now()
);

-- The workbooks' own "Historical Data" tab: weekly totals, notes and one-off amounts.
create table public.weekly_totals_history (
  week_ending     date primary key,
  fiscal_period   text,
  fiscal_year     integer,
  receipts        numeric(14,2),
  available_cash  numeric(14,2),
  disbursements   numeric(14,2),
  net_change      numeric(14,2),
  end_cash        numeric(14,2),
  note            text,
  one_off_amount  numeric(14,2)
);

do $$
declare t text;
begin
  foreach t in array array['history_sources', 'weekly_totals_history'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy read on public.%I for select to authenticated using (public.is_member())', t);
    execute format('grant select on public.%I to authenticated', t);   -- writes only through load_history()
  end loop;
end $$;

-- Bulk loads write one summary row to change_log per batch instead of one row per record.
create or replace function public.log_change() returns trigger
  language plpgsql security definer set search_path = public
  as $$
declare
  v_old jsonb; v_new jsonb; v_diff jsonb; v_key jsonb;
begin
  if current_setting('radar.bulk_load', true) = 'on' then return coalesce(new, old); end if;
  if tg_op in ('UPDATE', 'DELETE') then v_old := to_jsonb(old); end if;
  if tg_op in ('INSERT', 'UPDATE') then v_new := to_jsonb(new); end if;
  if tg_op = 'UPDATE' then
    select coalesce(jsonb_object_agg(k, jsonb_build_object('from', v_old -> k, 'to', v_new -> k)), '{}'::jsonb)
      into v_diff
      from jsonb_object_keys(v_new) as k
     where (v_old -> k) is distinct from (v_new -> k) and k <> 'updated_at';
    if v_diff = '{}'::jsonb then return new; end if;
  end if;
  select jsonb_object_agg(k, coalesce(v_new, v_old) -> k) into v_key from unnest(tg_argv) as k;
  insert into public.change_log (user_id, user_email, via, table_name, action, row_key, changed, old_row, new_row)
  values (auth.uid(), coalesce(auth.jwt() ->> 'email', session_user::text), public.current_via(),
          tg_table_name, lower(tg_op), v_key, v_diff, v_old, v_new);
  return coalesce(new, old);
end $$;

-- ---------------------------------------------------------------------
-- load_history(batch): admin-only, idempotent. Never changes existing weeks,
-- the current forecast, or anything Radar users have entered.
-- batch = { lines: [...], sources: [...], totals: [...], weeks: [...], snapshots: [...] }
-- ---------------------------------------------------------------------
create function public.load_history(p_batch jsonb) returns jsonb
  language plpgsql security definer set search_path = public as $$
declare
  v jsonb; s jsonb; v_snap uuid; n_lines int := 0; n_src int := 0; n_tot int := 0; n_wk int := 0; n_act int := 0; n_snap int := 0; n_val int := 0; c int;
begin
  if not public.is_admin() then raise exception 'Only admins can load history' using errcode = '42501'; end if;
  perform set_config('radar.bulk_load', 'on', true);

  -- history-only lines (archived, so they never appear in the live forecast)
  for v in select value from jsonb_array_elements(coalesce(p_batch -> 'lines', '[]')) loop
    insert into forecast_lines (key, name, kind, sort_order, note, category, archived_at)
    values (v ->> 'key', v ->> 'name', v ->> 'kind', 9000, 'Historical line', coalesce(v ->> 'category', 'flow'), now())
    on conflict (key) do nothing;
    get diagnostics c = row_count; n_lines := n_lines + c;
  end loop;

  insert into history_sources (week_ending, file_name, sha256, era, actuals_included, forecast_included, issues)
  select (x ->> 'week')::date, x ->> 'file', x ->> 'sha256', x ->> 'era', (x ->> 'actuals')::boolean, (x ->> 'forecast')::boolean, coalesce(x -> 'issues', '[]')
    from jsonb_array_elements(coalesce(p_batch -> 'sources', '[]')) x
  on conflict (week_ending) do nothing;
  get diagnostics n_src = row_count;

  insert into weekly_totals_history (week_ending, fiscal_period, fiscal_year, receipts, available_cash, disbursements, net_change, end_cash, note, one_off_amount)
  select (x ->> 'week')::date, x ->> 'period', (x ->> 'year')::int, (x ->> 'receipts')::numeric, (x ->> 'available')::numeric,
         (x ->> 'disbursements')::numeric, (x ->> 'net')::numeric, (x ->> 'end')::numeric, x ->> 'note', (x ->> 'oneOff')::numeric
    from jsonb_array_elements(coalesce(p_batch -> 'totals', '[]')) x
  on conflict (week_ending) do nothing;
  get diagnostics n_tot = row_count;

  -- weekly actuals: only for weeks that don't exist yet
  for v in select value from jsonb_array_elements(coalesce(p_batch -> 'weeks', '[]')) loop
    insert into week_closes (week_ending, start_cash, os_checks_start, os_checks_end, closed_by)
    values ((v ->> 'week')::date, (v ->> 'start')::numeric, 0, 0, auth.uid())
    on conflict (week_ending) do nothing;
    get diagnostics c = row_count;
    if c = 1 then
      n_wk := n_wk + 1;
      insert into weekly_actuals (week_ending, line_id, amount, source)
      select (v ->> 'week')::date, line_id_of(a.key), a.value::numeric, 'history'
        from jsonb_each_text(v -> 'lines') a;
      get diagnostics c = row_count; n_act := n_act + c;
    end if;
  end loop;

  -- frozen forecast snapshots, one per source workbook
  for s in select value from jsonb_array_elements(coalesce(p_batch -> 'snapshots', '[]')) loop
    insert into forecast_snapshots (as_of, starting_cash, reason, source_sha256, taken_at)
    values ((s ->> 'asOf')::date, (s ->> 'start')::numeric, 'historical workbook: ' || (s ->> 'file'), s ->> 'sha256',
            ((s ->> 'asOf')::date + 3)::timestamptz)
    on conflict (source_sha256) where source_sha256 is not null do nothing
    returning id into v_snap;
    if v_snap is not null then
      n_snap := n_snap + 1;
      insert into forecast_snapshot_values (snapshot_id, line_id, week_ending, amount)
      select v_snap, line_id_of(x ->> 'key'), (x ->> 'week')::date, (x ->> 'amount')::numeric
        from jsonb_array_elements(s -> 'values') x;
      get diagnostics c = row_count; n_val := n_val + c;
      v_snap := null;
    end if;
  end loop;

  perform set_config('radar.bulk_load', 'off', true);
  perform set_config('app.via', 'history-load', true);
  insert into change_log (user_id, user_email, via, table_name, action, row_key, new_row)
  values (auth.uid(), auth.jwt() ->> 'email', 'history-load', 'history', 'insert',
          jsonb_build_object('batch', p_batch ->> 'batch'),
          jsonb_build_object('lines', n_lines, 'sources', n_src, 'totals', n_tot, 'weeks', n_wk, 'actuals', n_act, 'snapshots', n_snap, 'snapshotValues', n_val));
  return jsonb_build_object('lines', n_lines, 'sources', n_src, 'totals', n_tot, 'weeks', n_wk, 'actuals', n_act, 'snapshots', n_snap, 'snapshotValues', n_val);
end $$;
revoke execute on function public.load_history(jsonb) from public, anon;
grant execute on function public.load_history(jsonb) to authenticated;

-- Keep the "latest forecast for last week" lookup on live snapshots when a historical one exists for the same week:
-- radar_state() orders by taken_at, and historical snapshots are stamped with their own (older) dates.

-- Reporting: accuracy by line category and horizon, plus the history-tab totals.
create or replace view reporting.forecast_accuracy as
  select s.as_of as forecast_made_for_week, v.week_ending,
         ((v.week_ending - s.as_of) / 7)::int as weeks_ahead,
         l.key as line_key, l.name as line_name, l.kind,
         v.amount as forecast, coalesce(a.amount, 0) as actual,
         coalesce(a.amount, 0) - v.amount as variance,
         l.category, s.source_sha256 is not null as from_history
    from public.forecast_snapshot_values v
    join public.forecast_snapshots s on s.id = v.snapshot_id
    join public.forecast_lines l on l.id = v.line_id
    join public.week_closes c on c.week_ending = v.week_ending
    left join public.weekly_actuals a on a.week_ending = v.week_ending and a.line_id = v.line_id
   where exists (select 1 from public.weekly_actuals x where x.week_ending = v.week_ending);

create view reporting.weekly_totals_history as select * from public.weekly_totals_history;
create view reporting.history_sources as
  select week_ending, file_name, era, actuals_included, forecast_included, issues from public.history_sources;
grant select on reporting.weekly_totals_history, reporting.history_sources, reporting.forecast_accuracy to radar_readonly;
