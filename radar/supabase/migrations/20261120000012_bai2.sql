-- BAI2 bank files: file format, daily bank balances, and no double counting when CSV and BAI2 cover the same days.

alter table public.bank_files add column format text not null default 'csv' check (format in ('csv', 'bai2'));

create table public.bank_balances (
  account_last4      text not null,
  account            text not null default '',
  as_of              date not null,
  opening_ledger     numeric(14,2),
  closing_ledger     numeric(14,2),
  opening_available  numeric(14,2),
  closing_available  numeric(14,2),
  credits            numeric(14,2) not null default 0,
  debits             numeric(14,2) not null default 0,
  ties               boolean,                 -- opening + credits - debits = closing
  file_id            uuid references public.bank_files (id) on delete set null,
  primary key (account_last4, as_of)
);
alter table public.bank_balances enable row level security;
create policy read on public.bank_balances for select to authenticated using (public.is_member());
create policy add on public.bank_balances for insert to authenticated with check (public.can_edit());
create policy edit on public.bank_balances for update to authenticated using (public.can_edit()) with check (public.can_edit());
grant select, insert, update on public.bank_balances to authenticated;     -- written through import_bank_file()
create trigger audit after insert or update on public.bank_balances
  for each row execute function public.log_change('account_last4', 'as_of');

create or replace function public.import_bank_file(p_file jsonb, p_txns jsonb) returns jsonb
  language plpgsql security invoker set search_path = public as $$
declare v_file uuid; v_new int; v_upd int; v_skip int; v_fmt text := coalesce(p_file ->> 'format', 'csv');
begin
  if not public.can_edit() then
    raise exception 'Only Radar editors can import bank files' using errcode = '42501';
  end if;
  perform public.set_via('import');

  insert into bank_files (file_name, storage_path, sha256, row_count, first_date, last_date, format)
  values (p_file ->> 'name', p_file ->> 'path', p_file ->> 'sha256', jsonb_array_length(p_txns),
          (p_file ->> 'firstDate')::date, (p_file ->> 'lastDate')::date, v_fmt)
  on conflict (sha256) do update set file_name = excluded.file_name
  returning id into v_file;

  -- transactions on account-days already stored from the other format are skipped (counted here, before inserting)
  select count(*) into v_skip from jsonb_array_elements(p_txns) t
   where exists (select 1 from bank_transactions x join bank_files f on f.id = x.file_id
                  where x.account_last4 = t ->> 'acct' and x.post_date = (t ->> 'date')::date and f.format <> v_fmt);

  with incoming as (
    select t ->> 'fp' as fingerprint, t ->> 'acct' as account_last4, coalesce(t ->> 'acctName', '') as account_name,
           (t ->> 'date')::date as post_date, (t ->> 'amount')::numeric as amount,
           coalesce(t ->> 'desc', '') as description, coalesce(t ->> 'ref', '') as reference,
           coalesce(t ->> 'ref2', '') as additional_reference, coalesce(t ->> 'text', '') as detail,
           coalesce(t ->> 'type', '') as txn_type, coalesce(t ->> 'trc', '') as trc,
           case when coalesce(t ->> 'line', '') in ('', 'ignore') then null else line_id_of(t ->> 'line') end as line_id,
           coalesce(t ->> 'line', '') = 'ignore' as ignored,
           case when t ->> 'line' is null or t ->> 'line' = '' then null when coalesce((t ->> 'manual')::boolean, false) then 'manual' else 'rule' end as categorized_by,
           (select id from import_rules where id::text = t ->> 'rule') as rule_id
      from jsonb_array_elements(p_txns) t),
  fresh as (
    select i.* from incoming i
     where not exists (select 1 from bank_transactions x join bank_files f on f.id = x.file_id
                        where x.account_last4 = i.account_last4 and x.post_date = i.post_date and f.format <> v_fmt)),
  up as (
    insert into bank_transactions (file_id, fingerprint, account_last4, account_name, post_date, amount, description,
                                   reference, additional_reference, detail, txn_type, trc, line_id, ignored, categorized_by, rule_id)
    select v_file, fingerprint, account_last4, account_name, post_date, amount, description,
           reference, additional_reference, detail, txn_type, trc, line_id, ignored, categorized_by, rule_id
      from fresh
    on conflict (fingerprint) do update set line_id = excluded.line_id, ignored = excluded.ignored,
      categorized_by = excluded.categorized_by, rule_id = excluded.rule_id
      where (bank_transactions.line_id, bank_transactions.ignored) is distinct from (excluded.line_id, excluded.ignored)
    returning (xmax = 0) as inserted)
  select count(*) filter (where inserted), count(*) filter (where not inserted) into v_new, v_upd from up;

  -- BAI2 balances, one row per account and day
  insert into bank_balances (account_last4, account, as_of, opening_ledger, closing_ledger, opening_available, closing_available, credits, debits, ties, file_id)
  select b ->> 'acct', coalesce(b ->> 'account', ''), (b ->> 'date')::date, (b ->> 'openingLedger')::numeric, (b ->> 'closingLedger')::numeric,
         (b ->> 'openingAvailable')::numeric, (b ->> 'closingAvailable')::numeric, coalesce((b ->> 'credits')::numeric, 0), coalesce((b ->> 'debits')::numeric, 0),
         (b ->> 'ties')::boolean, v_file
    from jsonb_array_elements(coalesce(p_file -> 'balances', '[]')) b
  on conflict (account_last4, as_of) do update set opening_ledger = excluded.opening_ledger, closing_ledger = excluded.closing_ledger,
    opening_available = excluded.opening_available, closing_available = excluded.closing_available, credits = excluded.credits,
    debits = excluded.debits, ties = excluded.ties, file_id = excluded.file_id;
  update week_closes set bank_file_id = v_file where week_ending = (p_file ->> 'weekEnding')::date;
  return jsonb_build_object('fileId', v_file, 'newTransactions', v_new, 'recategorized', v_upd,
                            'skippedOverlap', greatest(v_skip, 0),
                            'alreadyKnown', greatest(jsonb_array_length(p_txns) - v_new - v_upd - greatest(v_skip, 0), 0));
end $$;

create view reporting.bank_balances as
  select account_last4, as_of, opening_ledger, closing_ledger, opening_available, closing_available, credits, debits, ties from public.bank_balances;
grant select on reporting.bank_balances to radar_readonly, radar_hub;
