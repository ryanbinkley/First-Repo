-- Radar core schema
-- Design rules:
--   * Money is numeric(14,2) everywhere (exact cents, never floating point).
--   * Every change to a business table is written to change_log (who, when, how, old -> new).
--   * change_log and forecast snapshots are append-only.
--   * Access is limited to people listed in `members` (viewer / editor / admin), enforced by row-level security.

create extension if not exists pgcrypto;

-- =====================================================================
-- Members & roles
-- =====================================================================
create table public.members (
  user_id   uuid primary key references auth.users (id) on delete cascade,
  email     text not null,
  role      text not null check (role in ('viewer', 'editor', 'admin')),
  added_at  timestamptz not null default now()
);
comment on table public.members is 'Who can see Radar. viewer = read only, editor = can change forecasts and import, admin = can also manage members and delete imports.';

create function public.my_role() returns text
  language sql stable security definer set search_path = public
  as $$ select role from public.members where user_id = auth.uid() $$;
create function public.is_member() returns boolean
  language sql stable as $$ select public.my_role() is not null $$;
create function public.can_edit() returns boolean
  language sql stable as $$ select coalesce(public.my_role() in ('editor', 'admin'), false) $$;
create function public.is_admin() returns boolean
  language sql stable as $$ select coalesce(public.my_role() = 'admin', false) $$;

-- =====================================================================
-- Forecast model
-- =====================================================================
create table public.settings (
  id             smallint primary key default 1 check (id = 1),     -- single row
  company        text not null default '',
  as_of          date not null,                                     -- last week with actuals (week-ending Friday)
  starting_cash  numeric(14,2) not null,                            -- available cash, net of reserve & O/S checks
  min_cash       numeric(14,2) not null default 150000,             -- warning cushion
  flag_min       numeric(14,2) not null default 10000,              -- "significant outflow" threshold
  os_checks      numeric(14,2) not null default 0,                  -- outstanding checks as of as_of
  weeks          smallint not null default 13 check (weeks between 4 and 52),
  updated_at     timestamptz not null default now()
);

create table public.forecast_lines (
  id           uuid primary key default gen_random_uuid(),
  key          text not null unique,                                -- stable short id used by the app, e.g. 'payroll'
  name         text not null,
  kind         text not null check (kind in ('in', 'out')),
  sort_order   integer not null default 0,
  note         text not null default '',
  archived_at  timestamptz,
  created_at   timestamptz not null default now()
);

-- Effective-dated schedules: the row with the latest effective_from <= a week applies to that week.
-- effective_from IS NULL is the original schedule ("from the beginning").
create table public.line_schedules (
  id              uuid primary key default gen_random_uuid(),
  line_id         uuid not null references public.forecast_lines (id) on delete cascade,
  effective_from  date,
  freq            text not null check (freq in ('weekly', 'biweekly', 'monthly', 'none')),
  amount          numeric(14,2) not null default 0 check (amount >= 0),
  anchor          date,                                             -- biweekly: a week-ending date it occurs
  day_of_month    smallint check (day_of_month between 1 and 31),   -- monthly: due day
  last_week       boolean not null default false,                   -- monthly: last week of the month instead of a day
  months          smallint[] not null default '{}',                 -- monthly: limit to these months (empty = every month)
  shift_weeks     smallint not null default 0,                      -- schedule moved by whole weeks (drag "all future")
  created_at      timestamptz not null default now(),
  constraint biweekly_needs_anchor check (freq <> 'biweekly' or anchor is not null),
  constraint monthly_needs_day check (freq <> 'monthly' or last_week or day_of_month is not null),
  constraint months_valid check (months <@ array[1,2,3,4,5,6,7,8,9,10,11,12]::smallint[]),
  unique nulls not distinct (line_id, effective_from)
);

create table public.week_overrides (
  line_id      uuid not null references public.forecast_lines (id) on delete cascade,
  week_ending  date not null,
  amount       numeric(14,2) not null check (amount >= 0),
  primary key (line_id, week_ending)
);
comment on table public.week_overrides is 'Hand adjustments for a single week ("just this week").';

create table public.one_time_items (
  id           uuid primary key default gen_random_uuid(),
  line_id      uuid not null references public.forecast_lines (id) on delete cascade,
  item_date    date not null,
  description  text not null default '',
  amount       numeric(14,2) not null check (amount >= 0),
  created_at   timestamptz not null default now()
);
create index on public.one_time_items (item_date);

-- =====================================================================
-- Bank data
-- =====================================================================
create table public.import_rules (
  id             uuid primary key default gen_random_uuid(),
  priority       integer not null,                                  -- lower runs first; first match wins
  match_text     text not null default '',                          -- '' = matches anything
  direction      text not null default 'any' check (direction in ('any', 'in', 'out')),
  account_last4  text check (account_last4 ~ '^[0-9]{4}$'),
  action         text not null default 'categorize' check (action in ('categorize', 'ignore')),
  line_id        uuid references public.forecast_lines (id) on delete set null,
  created_at     timestamptz not null default now(),
  constraint categorize_needs_line check (action = 'ignore' or line_id is not null)
);

create table public.bank_files (
  id            uuid primary key default gen_random_uuid(),
  file_name     text not null,
  storage_path  text,                                               -- original CSV in the bank-files bucket
  sha256        text not null unique,                               -- same file can't be imported twice
  row_count     integer not null,
  first_date    date,
  last_date     date,
  uploaded_by   uuid default auth.uid(),
  uploaded_at   timestamptz not null default now()
);

create table public.bank_transactions (
  id                    uuid primary key default gen_random_uuid(),
  file_id               uuid not null references public.bank_files (id) on delete cascade,
  -- hash of account, date, amount and all description fields + occurrence number of identical rows,
  -- so an overlapping download never creates duplicates
  fingerprint           text not null unique,
  account_last4         text not null,
  account_name          text not null default '',
  post_date             date not null,
  amount                numeric(14,2) not null,                     -- + money in, - money out
  description           text not null default '',
  reference             text not null default '',
  additional_reference  text not null default '',
  detail                text not null default '',
  txn_type              text not null default '',
  trc                   text not null default '',
  line_id               uuid references public.forecast_lines (id) on delete set null,
  ignored               boolean not null default false,             -- internal transfer between our accounts
  categorized_by        text check (categorized_by in ('rule', 'manual')),
  rule_id               uuid references public.import_rules (id) on delete set null,
  created_at            timestamptz not null default now()
);
create index on public.bank_transactions (post_date);
create index on public.bank_transactions (line_id);

-- =====================================================================
-- Weekly actuals & forecast history
-- =====================================================================
create table public.week_closes (
  week_ending      date primary key,
  start_cash       numeric(14,2) not null,
  os_checks_start  numeric(14,2) not null default 0,
  os_checks_end    numeric(14,2) not null default 0,
  bank_file_id     uuid references public.bank_files (id) on delete set null,
  closed_by        uuid default auth.uid(),
  closed_at        timestamptz not null default now()
);

create table public.weekly_actuals (
  week_ending  date not null references public.week_closes (week_ending) on delete cascade,
  line_id      uuid not null references public.forecast_lines (id),
  amount       numeric(14,2) not null,
  source       text not null default 'manual' check (source in ('import', 'manual')),
  primary key (week_ending, line_id)
);

-- Frozen copy of the 13-week forecast, taken every time a new week starts. Never edited.
create table public.forecast_snapshots (
  id             uuid primary key default gen_random_uuid(),
  as_of          date not null,
  starting_cash  numeric(14,2) not null,
  reason         text not null default 'weekly roll-forward',
  taken_by       uuid default auth.uid(),
  taken_at       timestamptz not null default now()
);
create index on public.forecast_snapshots (as_of);

create table public.forecast_snapshot_values (
  snapshot_id  uuid not null references public.forecast_snapshots (id),
  line_id      uuid not null references public.forecast_lines (id),
  week_ending  date not null,
  amount       numeric(14,2) not null,
  primary key (snapshot_id, line_id, week_ending)
);

-- =====================================================================
-- Change log (append-only audit trail)
-- =====================================================================
create table public.change_log (
  id          bigint generated always as identity primary key,
  at          timestamptz not null default now(),
  user_id     uuid,
  user_email  text,
  via         text not null default 'unknown',                      -- radar | assistant | import | system | sql
  table_name  text not null,
  action      text not null check (action in ('insert', 'update', 'delete')),
  row_key     jsonb not null,
  changed     jsonb,                                                -- update: {"field": {"from": .., "to": ..}}
  old_row     jsonb,
  new_row     jsonb
);
create index on public.change_log (at desc);
create index on public.change_log (table_name, at desc);

-- How a change was made: an RPC can `set_config('app.via', 'assistant', true)`;
-- browser/API calls can send the header `x-radar-via`.
create function public.current_via() returns text language sql stable as $$
  select coalesce(
    nullif(current_setting('app.via', true), ''),
    nullif(current_setting('request.headers', true), '')::json ->> 'x-radar-via',
    case when auth.uid() is null then 'sql' else 'unknown' end)
$$;

create function public.log_change() returns trigger
  language plpgsql security definer set search_path = public
  as $$
declare
  v_old jsonb; v_new jsonb; v_diff jsonb; v_key jsonb;
begin
  if tg_op in ('UPDATE', 'DELETE') then v_old := to_jsonb(old); end if;
  if tg_op in ('INSERT', 'UPDATE') then v_new := to_jsonb(new); end if;
  if tg_op = 'UPDATE' then
    select coalesce(jsonb_object_agg(k, jsonb_build_object('from', v_old -> k, 'to', v_new -> k)), '{}'::jsonb)
      into v_diff
      from jsonb_object_keys(v_new) as k
     where (v_old -> k) is distinct from (v_new -> k) and k <> 'updated_at';
    if v_diff = '{}'::jsonb then return new; end if;                -- nothing really changed
  end if;
  select jsonb_object_agg(k, coalesce(v_new, v_old) -> k) into v_key from unnest(tg_argv) as k;
  insert into public.change_log (user_id, user_email, via, table_name, action, row_key, changed, old_row, new_row)
  values (auth.uid(), coalesce(auth.jwt() ->> 'email', session_user::text), public.current_via(),
          tg_table_name, lower(tg_op), v_key, v_diff, v_old, v_new);
  return coalesce(new, old);
end $$;

create function public.forbid_change() returns trigger language plpgsql as $$
begin
  raise exception '% is append-only: rows cannot be changed or deleted', tg_table_name;
end $$;

create trigger change_log_append_only before update or delete on public.change_log
  for each row execute function public.forbid_change();
create trigger change_log_no_truncate before truncate on public.change_log
  for each statement execute function public.forbid_change();
create trigger snapshots_append_only before update or delete on public.forecast_snapshots
  for each row execute function public.forbid_change();
create trigger snapshot_values_append_only before update or delete on public.forecast_snapshot_values
  for each row execute function public.forbid_change();

create function public.touch_updated_at() returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;
create trigger settings_touch before update on public.settings for each row execute function public.touch_updated_at();

-- Audit triggers (trigger arguments = key columns recorded in row_key)
create trigger audit after insert or update or delete on public.settings          for each row execute function public.log_change('id');
create trigger audit after insert or update or delete on public.forecast_lines    for each row execute function public.log_change('id', 'key');
create trigger audit after insert or update or delete on public.line_schedules    for each row execute function public.log_change('id', 'line_id', 'effective_from');
create trigger audit after insert or update or delete on public.week_overrides    for each row execute function public.log_change('line_id', 'week_ending');
create trigger audit after insert or update or delete on public.one_time_items    for each row execute function public.log_change('id');
create trigger audit after insert or update or delete on public.import_rules      for each row execute function public.log_change('id');
create trigger audit after insert or update or delete on public.bank_files        for each row execute function public.log_change('id', 'file_name');
create trigger audit after update or delete on public.bank_transactions           for each row execute function public.log_change('id', 'post_date');  -- inserts are covered by bank_files
create trigger audit after insert or update or delete on public.week_closes       for each row execute function public.log_change('week_ending');
create trigger audit after insert or update or delete on public.weekly_actuals    for each row execute function public.log_change('week_ending', 'line_id');
create trigger audit after insert or update or delete on public.members           for each row execute function public.log_change('user_id', 'email');
create trigger audit after insert on public.forecast_snapshots                    for each row execute function public.log_change('id', 'as_of');

-- =====================================================================
-- Row-level security
-- =====================================================================
do $$
declare t text;
begin
  -- tables any member can read and editors can change
  foreach t in array array['settings', 'forecast_lines', 'line_schedules', 'week_overrides', 'one_time_items',
                           'import_rules', 'week_closes', 'weekly_actuals'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy read on public.%I for select to authenticated using (public.is_member())', t);
    execute format('create policy add on public.%I for insert to authenticated with check (public.can_edit())', t);
    execute format('create policy edit on public.%I for update to authenticated using (public.can_edit()) with check (public.can_edit())', t);
    execute format('create policy remove on public.%I for delete to authenticated using (public.can_edit())', t);
  end loop;

  -- imported bank data: editors add and re-categorize; only admins delete
  foreach t in array array['bank_files', 'bank_transactions'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy read on public.%I for select to authenticated using (public.is_member())', t);
    execute format('create policy add on public.%I for insert to authenticated with check (public.can_edit())', t);
    execute format('create policy edit on public.%I for update to authenticated using (public.can_edit()) with check (public.can_edit())', t);
    execute format('create policy remove on public.%I for delete to authenticated using (public.is_admin())', t);
  end loop;

  -- history: members read, editors add, nobody edits (append-only triggers above)
  foreach t in array array['forecast_snapshots', 'forecast_snapshot_values'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy read on public.%I for select to authenticated using (public.is_member())', t);
    execute format('create policy add on public.%I for insert to authenticated with check (public.can_edit())', t);
  end loop;
end $$;

alter table public.change_log enable row level security;
create policy read on public.change_log for select to authenticated using (public.is_member());
-- no insert/update/delete policies: rows only arrive through the audit trigger

alter table public.members enable row level security;
create policy read on public.members for select to authenticated using (public.is_member());
create policy manage on public.members for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- Nothing is visible without signing in.
revoke all on all tables in schema public from anon;
revoke all on all functions in schema public from anon;
revoke update, delete, truncate on public.change_log from authenticated;
