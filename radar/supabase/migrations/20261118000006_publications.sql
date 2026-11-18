-- "Publish update": a permanent record each time an editor announces a new weekly forecast.
create table public.forecast_publications (
  id                  uuid primary key default gen_random_uuid(),
  as_of               date not null,
  note                text not null default '',
  summary             jsonb not null default '{}',
  recipients          integer not null default 0,
  published_by        uuid not null default auth.uid(),
  published_by_email  text not null default coalesce(auth.jwt() ->> 'email', ''),
  published_at        timestamptz not null default now()
);
create index on public.forecast_publications (published_at desc);

alter table public.forecast_publications enable row level security;
create policy read on public.forecast_publications for select to authenticated using (public.is_member());
create policy add on public.forecast_publications for insert to authenticated
  with check (public.can_edit() and published_by = auth.uid());
grant select, insert on public.forecast_publications to authenticated;

create trigger publications_append_only before update or delete on public.forecast_publications
  for each row execute function public.forbid_change();
create trigger audit after insert on public.forecast_publications
  for each row execute function public.log_change('id', 'as_of');

create view reporting.forecast_publications as
  select as_of, published_at, published_by_email, note, recipients, summary from public.forecast_publications;
grant select on reporting.forecast_publications to radar_readonly;
