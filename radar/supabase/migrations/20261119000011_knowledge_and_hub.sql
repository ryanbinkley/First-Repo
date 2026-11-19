-- "What Radar should know": notes and questions/answers between Radar and people,
-- plus the AI hub's door into Radar: read-only reporting views and a write-only drop box for its reports.

-- Notes people add, and questions Radar (its engine or the AI analyst) asks, with answers.
create table public.radar_knowledge (
  id           uuid primary key default gen_random_uuid(),
  qkey         text unique,                       -- de-duplicates engine questions, e.g. 'departure:other_in:80000'
  line_key     text,                              -- optional: which forecast line it's about
  kind         text not null check (kind in ('note', 'question')),
  source       text not null check (source in ('person', 'engine', 'analyst')),
  question     text,
  body         text,                              -- the note, or the answer to a question
  status       text not null default 'open' check (status in ('open', 'answered', 'dismissed')),
  suggestion_id text,                             -- question linked to a Radar suggestion, e.g. 'other_in:departure'
  created_by   uuid default auth.uid(),
  created_by_email text default coalesce(auth.jwt() ->> 'email', ''),
  created_at   timestamptz not null default now(),
  answered_by_email text,
  answered_at  timestamptz,
  constraint note_has_body check (kind <> 'note' or body is not null),
  constraint question_has_text check (kind <> 'question' or question is not null)
);
create index on public.radar_knowledge (status, created_at desc);
alter table public.radar_knowledge enable row level security;
create policy read on public.radar_knowledge for select to authenticated using (public.is_member());
create policy add on public.radar_knowledge for insert to authenticated with check (public.can_edit() and source in ('person', 'engine'));
create policy answer on public.radar_knowledge for update to authenticated using (public.can_edit()) with check (public.can_edit());
grant select, insert, update on public.radar_knowledge to authenticated;
create trigger audit after insert or update or delete on public.radar_knowledge
  for each row execute function public.log_change('id', 'kind');

-- Reports written by the AI analyst (the hub). Radar shows the latest one for the current week.
create table public.analyst_reports (
  id          uuid primary key default gen_random_uuid(),
  as_of       date not null,
  model       text not null default '',
  summary     text not null default '',
  themes      jsonb not null default '[]',   -- [{title, text, lines: [line_key], evidence: [ "numbers it relied on" ]}]
  created_at  timestamptz not null default now()
);
create index on public.analyst_reports (as_of, created_at desc);
alter table public.analyst_reports enable row level security;
create policy read on public.analyst_reports for select to authenticated using (public.is_member());
grant select on public.analyst_reports to authenticated;
create trigger analyst_reports_append_only before update or delete on public.analyst_reports for each row execute function public.forbid_change();
create trigger audit after insert on public.analyst_reports for each row execute function public.log_change('id', 'as_of');

-- The plan by line and week travels with each saved Radar run, so the hub sees both forecasts.
alter table public.machine_runs add column plan jsonb not null default '{}';   -- {line_key: {week: amount}}

-- ---------------------------------------------------------------------
-- The hub's login: reads the reporting views; may only add analyst reports and questions.
-- An admin turns on login with:  alter role radar_hub with login password '...';
-- ---------------------------------------------------------------------
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'radar_hub') then create role radar_hub nologin; end if;
end $$;
grant usage on schema reporting to radar_hub;
grant usage on schema public to radar_hub;

-- The hub writes only through these two functions (no direct table access).
create function public.hub_add_report(p_as_of date, p_model text, p_summary text, p_themes jsonb) returns uuid
  language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  if jsonb_typeof(coalesce(p_themes, '[]')) <> 'array' then raise exception 'themes must be a JSON array'; end if;
  insert into analyst_reports (as_of, model, summary, themes) values (p_as_of, coalesce(p_model, ''), coalesce(p_summary, ''), coalesce(p_themes, '[]'))
  returning id into v;
  return v;
end $$;
create function public.hub_add_question(p_question text, p_line_key text default null, p_qkey text default null) returns uuid
  language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  if coalesce(trim(p_question), '') = '' then raise exception 'question is empty'; end if;
  insert into radar_knowledge (kind, source, question, line_key, qkey, created_by, created_by_email)
  values ('question', 'analyst', trim(p_question), p_line_key, p_qkey, null, 'Radar analyst')
  on conflict (qkey) do nothing returning id into v;
  return v;
end $$;
revoke execute on function public.hub_add_report(date, text, text, jsonb), public.hub_add_question(text, text, text) from public, anon, authenticated;
grant execute on function public.hub_add_report(date, text, text, jsonb), public.hub_add_question(text, text, text) to radar_hub;

-- Reporting views for the hub and dashboards
create view reporting.radar_knowledge as
  select id, line_key, kind, source, question, body, status, suggestion_id, created_by_email, created_at, answered_by_email, answered_at
    from public.radar_knowledge;
create view reporting.analyst_reports as select * from public.analyst_reports;
create or replace view reporting.machine_latest as
  select distinct on (as_of) as_of, created_at, engine_version, suggestions, cols, facts, plan
    from public.machine_runs order by as_of, created_at desc;
create view reporting.current_week as
  select as_of, starting_cash, min_cash, flag_min, os_checks, weeks from public.settings;

grant select on all tables in schema reporting to radar_readonly, radar_hub;
