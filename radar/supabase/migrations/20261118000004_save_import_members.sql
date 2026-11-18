-- Write API for the Radar app. Each call runs as one transaction with the caller's
-- rights (row-level security applies) and is recorded in change_log.

create function public.line_id_of(p_key text) returns uuid
  language plpgsql stable set search_path = public as $$
declare v uuid;
begin
  select id into v from forecast_lines where key = p_key;
  if v is null then raise exception 'Unknown forecast line "%"', p_key; end if;
  return v;
end $$;

create function public.set_via(p_default text) returns void language sql as $$
  select set_config('app.via',
    coalesce(nullif(nullif(current_setting('request.headers', true), '')::json ->> 'x-radar-via', ''), p_default), true)
$$;

-- ---------------------------------------------------------------------
-- save_radar(ops): apply a batch of changes from the app, all or nothing.
-- ---------------------------------------------------------------------
create function public.save_radar(p_ops jsonb) returns jsonb
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
      insert into forecast_snapshots (as_of, starting_cash, reason)
      values ((op ->> 'asOf')::date, (op ->> 'startingCash')::numeric, coalesce(op ->> 'reason', 'weekly roll-forward'))
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

-- ---------------------------------------------------------------------
-- import_bank_file(file, txns): store a bank download and its transactions.
-- Re-importing the same file, or an overlapping one, never duplicates rows;
-- it only updates categories that changed.
-- ---------------------------------------------------------------------
create function public.import_bank_file(p_file jsonb, p_txns jsonb) returns jsonb
  language plpgsql security invoker set search_path = public as $$
declare v_file uuid; v_new int; v_upd int;
begin
  if not public.can_edit() then
    raise exception 'Only Radar editors can import bank files' using errcode = '42501';
  end if;
  perform public.set_via('import');

  insert into bank_files (file_name, storage_path, sha256, row_count, first_date, last_date)
  values (p_file ->> 'name', p_file ->> 'path', p_file ->> 'sha256', jsonb_array_length(p_txns),
          (p_file ->> 'firstDate')::date, (p_file ->> 'lastDate')::date)
  on conflict (sha256) do update set file_name = excluded.file_name
  returning id into v_file;

  with incoming as (
    select t ->> 'fp' as fingerprint, t ->> 'acct' as account_last4, coalesce(t ->> 'acctName', '') as account_name,
           (t ->> 'date')::date as post_date, (t ->> 'amount')::numeric as amount,
           coalesce(t ->> 'desc', '') as description, coalesce(t ->> 'ref', '') as reference,
           coalesce(t ->> 'ref2', '') as additional_reference, coalesce(t ->> 'text', '') as detail,
           coalesce(t ->> 'type', '') as txn_type, coalesce(t ->> 'trc', '') as trc,
           case when coalesce(t ->> 'line', '') in ('', 'ignore') then null else line_id_of(t ->> 'line') end as line_id,
           t ->> 'line' = 'ignore' as ignored,
           case when t ->> 'line' is null or t ->> 'line' = '' then null when (t ->> 'manual')::boolean then 'manual' else 'rule' end as categorized_by,
           (select id from import_rules where id::text = t ->> 'rule') as rule_id
      from jsonb_array_elements(p_txns) t),
  up as (
    insert into bank_transactions (file_id, fingerprint, account_last4, account_name, post_date, amount, description,
                                   reference, additional_reference, detail, txn_type, trc, line_id, ignored, categorized_by, rule_id)
    select v_file, fingerprint, account_last4, account_name, post_date, amount, description,
           reference, additional_reference, detail, txn_type, trc, line_id, ignored, categorized_by, rule_id
      from incoming
    on conflict (fingerprint) do update set line_id = excluded.line_id, ignored = excluded.ignored,
      categorized_by = excluded.categorized_by, rule_id = excluded.rule_id
      where (bank_transactions.line_id, bank_transactions.ignored) is distinct from (excluded.line_id, excluded.ignored)
    returning (xmax = 0) as inserted)
  select count(*) filter (where inserted), count(*) filter (where not inserted) into v_new, v_upd from up;

  update week_closes set bank_file_id = v_file where week_ending = (p_file ->> 'weekEnding')::date;
  return jsonb_build_object('fileId', v_file, 'newTransactions', v_new, 'recategorized', v_upd,
                            'alreadyKnown', jsonb_array_length(p_txns) - v_new - v_upd);
end $$;

-- ---------------------------------------------------------------------
-- Members (admins only). People must sign in once before they can be added.
-- ---------------------------------------------------------------------
create function public.set_member(p_email text, p_role text) returns void
  language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Only admins can manage access' using errcode = '42501'; end if;
  if p_role not in ('viewer', 'editor', 'admin') then raise exception 'Role must be viewer, editor or admin'; end if;
  perform public.set_via('radar');
  insert into members (user_id, email, role)
  select id, email, p_role from auth.users where lower(email) = lower(trim(p_email))
  on conflict (user_id) do update set role = excluded.role;
  if not found then
    raise exception '% has not signed in to Radar yet. Ask them to sign in once, then add them.', p_email;
  end if;
end $$;

create function public.remove_member(p_email text) returns void
  language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Only admins can manage access' using errcode = '42501'; end if;
  if lower(trim(p_email)) = lower(auth.jwt() ->> 'email') then raise exception 'You cannot remove yourself'; end if;
  perform public.set_via('radar');
  delete from members where lower(email) = lower(trim(p_email));
end $$;

-- Signed-in user's own email and role (null role = not a member yet)
create function public.whoami() returns jsonb
  language sql stable security definer set search_path = public as $$
  select jsonb_build_object('email', auth.jwt() ->> 'email', 'role', (select role from members where user_id = auth.uid()))
$$;

revoke execute on function public.line_id_of(text), public.set_via(text), public.save_radar(jsonb),
  public.import_bank_file(jsonb, jsonb), public.set_member(text, text), public.remove_member(text), public.whoami()
  from public, anon;
grant execute on function public.line_id_of(text), public.set_via(text), public.save_radar(jsonb),
  public.import_bank_file(jsonb, jsonb), public.set_member(text, text), public.remove_member(text), public.whoami()
  to authenticated;

-- Live updates: the app listens for new change_log rows (row-level security still applies).
do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.change_log;
  end if;
end $$;

-- Tighten: functions from earlier migrations are callable by signed-in users only.
revoke execute on function public.radar_state(), public.schedule_json(public.line_schedules),
  public.my_role(), public.is_member(), public.can_edit(), public.is_admin() from public, anon;
grant execute on function public.radar_state(), public.schedule_json(public.line_schedules),
  public.my_role(), public.is_member(), public.can_edit(), public.is_admin() to authenticated;
