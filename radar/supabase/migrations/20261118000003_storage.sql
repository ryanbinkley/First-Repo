-- Private bucket for the original bank CSV files (kept as the source record of every import)
insert into storage.buckets (id, name, public) values ('bank-files', 'bank-files', false)
  on conflict (id) do nothing;

create policy "bank files: members read" on storage.objects for select to authenticated
  using (bucket_id = 'bank-files' and public.is_member());
create policy "bank files: editors upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'bank-files' and public.can_edit());
create policy "bank files: admins delete" on storage.objects for delete to authenticated
  using (bucket_id = 'bank-files' and public.is_admin());
