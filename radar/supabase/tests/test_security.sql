-- Security & audit tests. Run after the stub, the migrations and a seed (see run_local.sh).
-- Each block raises an exception (and stops the run) if a rule is broken.
\set ON_ERROR_STOP on
set client_min_messages = warning;

insert into auth.users values
  ('00000000-0000-0000-0000-00000000000a', 'admin@example.com'),
  ('00000000-0000-0000-0000-00000000000e', 'editor@example.com'),
  ('00000000-0000-0000-0000-00000000000f', 'viewer@example.com'),
  ('00000000-0000-0000-0000-00000000000b', 'stranger@example.com');
insert into public.members (user_id, email, role) values
  ('00000000-0000-0000-0000-00000000000a', 'admin@example.com', 'admin'),
  ('00000000-0000-0000-0000-00000000000e', 'editor@example.com', 'editor'),
  ('00000000-0000-0000-0000-00000000000f', 'viewer@example.com', 'viewer');

create or replace function pg_temp.act_as(who text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', (select id from auth.users where email = who), 'email', who)::text, false);
  perform set_config('request.headers', '{"x-radar-via":"radar"}', false);
end $$;

-- 1. Signed-out visitors see nothing ---------------------------------
set role anon;
do $$ begin
  begin perform 1 from public.settings; raise exception 'FAIL: anon can read settings';
  exception when insufficient_privilege then null; end;
end $$;
reset role;

-- 2. Signed-in non-members see no rows -------------------------------
select pg_temp.act_as('stranger@example.com'); set role authenticated;
do $$ begin
  if (select count(*) from public.forecast_lines) <> 0 then raise exception 'FAIL: non-member sees forecast lines'; end if;
  if public.radar_state() is not null then raise exception 'FAIL: non-member gets radar_state'; end if;
end $$;
reset role;

-- 3. Viewers read but cannot change -----------------------------------
select pg_temp.act_as('viewer@example.com'); set role authenticated;
do $$ declare n int; begin
  if (select count(*) from public.forecast_lines) = 0 then raise exception 'FAIL: viewer cannot read'; end if;
  update public.settings set min_cash = 1 where id = 1;
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'FAIL: viewer changed settings'; end if;
  begin insert into public.one_time_items (line_id, item_date, amount)
        values ((select id from public.forecast_lines limit 1), '2027-01-08', 1);
        raise exception 'FAIL: viewer added an item';
  exception when insufficient_privilege then null; end;
end $$;
reset role;

-- 4. Editors change things, and every change is logged with who / how / old -> new
select pg_temp.act_as('editor@example.com'); set role authenticated;
do $$ declare before bigint; c record; begin
  select count(*) into before from public.change_log;
  update public.settings set min_cash = 175000 where id = 1;
  update public.settings set min_cash = 175000 where id = 1;          -- no-op: must not be logged
  insert into public.one_time_items (line_id, item_date, description, amount)
    values ((select id from public.forecast_lines where kind = 'out' order by sort_order limit 1), '2027-01-08', 'Roof repair', 40000.10);
  if (select count(*) from public.change_log) <> before + 2 then raise exception 'FAIL: expected exactly 2 new log rows'; end if;
  select * into c from public.change_log where table_name = 'settings' order by id desc limit 1;
  if c.user_email <> 'editor@example.com' or c.via <> 'radar' or c.action <> 'update'
     or (c.changed -> 'min_cash' ->> 'to')::numeric <> 175000 then
    raise exception 'FAIL: change_log row wrong: %', row_to_json(c); end if;
  -- exact cents
  if (select amount from public.one_time_items where description = 'Roof repair') <> 40000.10 then
    raise exception 'FAIL: money not stored exactly'; end if;
end $$;

-- 5. The change log cannot be altered, even by an admin or the database owner
do $$ begin
  begin update public.change_log set via = 'x'; raise exception 'FAIL: editor updated change_log';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
do $$ begin
  begin update public.change_log set via = 'x'; raise exception 'FAIL: owner updated change_log';
  exception when raise_exception then null; end;
  begin delete from public.change_log; raise exception 'FAIL: owner deleted change_log';
  exception when raise_exception then null; end;
end $$;

-- 6. Imported transactions can't be duplicated; only admins can delete imports
select pg_temp.act_as('editor@example.com'); set role authenticated;
do $$ declare f uuid; n int; begin
  insert into public.bank_files (file_name, sha256, row_count) values ('test.csv', 'abc', 1) returning id into f;
  insert into public.bank_transactions (file_id, fingerprint, account_last4, post_date, amount)
    values (f, 'fp-1', '4996', '2026-11-13', -12.34);
  begin insert into public.bank_transactions (file_id, fingerprint, account_last4, post_date, amount)
          values (f, 'fp-1', '4996', '2026-11-13', -12.34);
        raise exception 'FAIL: duplicate transaction accepted';
  exception when unique_violation then null; end;
  begin insert into public.bank_files (file_name, sha256, row_count) values ('again.csv', 'abc', 1);
        raise exception 'FAIL: same file imported twice';
  exception when unique_violation then null; end;
  delete from public.bank_files where sha256 = 'abc';
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'FAIL: editor deleted an import'; end if;
end $$;
reset role;
select pg_temp.act_as('admin@example.com'); set role authenticated;
do $$ declare n int; begin
  delete from public.bank_files where sha256 = 'abc';
  get diagnostics n = row_count;
  if n <> 1 then raise exception 'FAIL: admin could not delete an import'; end if;
end $$;
reset role;

-- 7. Forecast snapshots are frozen
do $$ begin
  begin update public.forecast_snapshot_values set amount = 0; raise exception 'FAIL: snapshot edited';
  exception when raise_exception then null; end;
end $$;

-- 8. The read-only reporting role sees reporting views and nothing else
set role radar_readonly;
do $$ begin
  perform count(*) from reporting.week_summary;
  perform count(*) from reporting.forecast_accuracy;
  begin perform 1 from public.bank_transactions; raise exception 'FAIL: readonly role reads public tables';
  exception when insufficient_privilege then null; end;
end $$;
reset role;

-- 9. Invitations: admin pre-authorizes an email; first confirmed sign-in grants access
select pg_temp.act_as('admin@example.com'); set role authenticated;
do $$ begin
  if public.set_member('NewPerson@Example.com', 'editor') <> 'invited' then raise exception 'FAIL: invite not created'; end if;
  if public.set_member('viewer@example.com', 'editor') <> 'added' then raise exception 'FAIL: existing user not updated'; end if;
  perform public.set_member('viewer@example.com', 'viewer');
  if (select count(*) from public.member_invites) <> 1 then raise exception 'FAIL: admin cannot see invites'; end if;
end $$;
reset role;
select pg_temp.act_as('editor@example.com'); set role authenticated;
do $$ begin
  if (select count(*) from public.member_invites) <> 0 then raise exception 'FAIL: non-admin sees invites'; end if;
  begin perform public.set_member('x@example.com', 'admin'); raise exception 'FAIL: editor invited someone';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
insert into auth.users (id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-0000000000c1', 'newperson@example.com', null);   -- not confirmed yet
select pg_temp.act_as('newperson@example.com'); set role authenticated;
do $$ begin
  if public.whoami() ->> 'role' is not null then raise exception 'FAIL: unconfirmed email claimed an invite'; end if;
end $$;
reset role;
update auth.users set email_confirmed_at = now() where email = 'newperson@example.com';
select pg_temp.act_as('newperson@example.com'); set role authenticated;
do $$ begin
  if public.whoami() ->> 'role' <> 'editor' then raise exception 'FAIL: invite not accepted on sign-in'; end if;
  if (select count(*) from public.forecast_lines) = 0 then raise exception 'FAIL: invited editor cannot read'; end if;
end $$;
reset role;
do $$ begin
  if exists (select 1 from public.member_invites) then raise exception 'FAIL: invite not cleared'; end if;
  if not exists (select 1 from public.change_log where table_name = 'members' and via = 'invite') then raise exception 'FAIL: invite acceptance not logged'; end if;
end $$;

-- 10. History loading: admins only, never overwrites existing weeks, history tables read-only otherwise
select pg_temp.act_as('editor@example.com'); set role authenticated;
do $$ begin
  begin perform public.load_history('{"batch":"x"}'); raise exception 'FAIL: editor loaded history';
  exception when insufficient_privilege then null; end;
  begin insert into public.weekly_totals_history (week_ending) values ('2020-01-03'); raise exception 'FAIL: editor wrote history totals';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
select pg_temp.act_as('admin@example.com'); set role authenticated;
do $$ declare r jsonb; before numeric; begin
  select start_cash into before from public.week_closes order by week_ending desc limit 1;
  r := public.load_history(jsonb_build_object('batch', 'test',
    'lines', jsonb_build_array(jsonb_build_object('key', 'old_line', 'name', 'Old line', 'kind', 'out')),
    'weeks', jsonb_build_array(
       jsonb_build_object('week', '2024-01-05', 'start', 100, 'lines', jsonb_build_object('old_line', 12.34)),
       jsonb_build_object('week', (select week_ending from public.week_closes order by week_ending desc limit 1), 'start', 1, 'lines', '{}'::jsonb)),
    'snapshots', jsonb_build_array(jsonb_build_object('asOf', '2023-12-29', 'start', 100, 'file', 'f.xlsx', 'sha256', 'abc123',
       'values', jsonb_build_array(jsonb_build_object('key', 'old_line', 'week', '2024-01-05', 'amount', 10))))));
  if (r ->> 'weeks')::int <> 1 or (r ->> 'snapshots')::int <> 1 then raise exception 'FAIL: history load counts %', r; end if;
  if (select start_cash from public.week_closes order by week_ending desc limit 1) <> before then raise exception 'FAIL: history overwrote an existing week'; end if;
  if (select archived_at from public.forecast_lines where key = 'old_line') is null then raise exception 'FAIL: history line not archived'; end if;
  r := public.load_history(jsonb_build_object('batch', 'again', 'snapshots', jsonb_build_array(jsonb_build_object('asOf', '2023-12-29', 'start', 100, 'file', 'f.xlsx', 'sha256', 'abc123', 'values', '[]'::jsonb))));
  if (r ->> 'snapshots')::int <> 0 then raise exception 'FAIL: same workbook loaded twice'; end if;
  if (select count(*) from public.change_log where via = 'history-load') <> 2 then raise exception 'FAIL: expected one summary log row per batch'; end if;
end $$;
reset role;
do $$ begin
  if (select count(*) from reporting.forecast_accuracy where week_ending = '2024-01-05' and line_key = 'old_line' and actual = 12.34) <> 1 then
    raise exception 'FAIL: accuracy view missing history row'; end if;
end $$;

-- 11. The AI hub's login: reads reporting views, writes only reports/questions through its two functions
set role radar_hub;
do $$ declare q1 uuid; q2 uuid; begin
  perform count(*) from reporting.machine_latest; perform count(*) from reporting.radar_knowledge; perform count(*) from reporting.current_week;
  begin perform 1 from reporting.bank_transactions; raise exception 'FAIL: hub reads bank transactions'; exception when insufficient_privilege then null; end;
  begin perform 1 from public.settings; raise exception 'FAIL: hub reads public tables'; exception when insufficient_privilege then null; end;
  begin perform public.save_radar('[]'); raise exception 'FAIL: hub changed the forecast'; exception when insufficient_privilege then null; end;
  begin update public.radar_knowledge set body = 'x'; raise exception 'FAIL: hub answered a question'; exception when insufficient_privilege then null; end;
  perform public.hub_add_report('2026-11-13', 'test-model', 'Summary $1,000', '[{"title":"T","text":"x"}]');
  q1 := public.hub_add_question('Was the October dip from advertising?', 'other_in', 'analyst:oct-dip');
  q2 := public.hub_add_question('Was the October dip from advertising?', 'other_in', 'analyst:oct-dip');   -- same question again
  if q1 is null or q2 is not null then raise exception 'FAIL: hub question not de-duplicated'; end if;
  begin perform public.hub_add_report('2026-11-13', 'm', 's', '{"not":"an array"}'); raise exception 'FAIL: bad themes accepted'; exception when raise_exception then null; end;
end $$;
reset role;
select pg_temp.act_as('editor@example.com'); set role authenticated;
do $$ begin
  begin perform public.hub_add_report('2026-11-13', 'm', 's', '[]'); raise exception 'FAIL: user called a hub function'; exception when insufficient_privilege then null; end;
  if (select count(*) from public.analyst_reports) <> 1 then raise exception 'FAIL: members cannot read analyst reports'; end if;
  update public.radar_knowledge set body = 'Yes, two advertisers paused', status = 'answered' where qkey = 'analyst:oct-dip';
  if not found then raise exception 'FAIL: editor cannot answer'; end if;
  insert into public.radar_knowledge (kind, source, body) values ('note', 'person', 'A large advertiser cancelled in October');
  begin insert into public.radar_knowledge (kind, source, question) values ('question', 'analyst', 'pretend'); raise exception 'FAIL: user posed as analyst';
  exception when insufficient_privilege then null; end;
end $$;
reset role;

select 'ALL SECURITY TESTS PASSED' as result;
