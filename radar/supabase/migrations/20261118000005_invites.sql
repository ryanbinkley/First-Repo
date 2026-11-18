-- Invitations: an admin pre-authorizes an email address with a role. The first time that
-- person signs in (which proves they own the address), they become a member automatically.

create table public.member_invites (
  email       text primary key check (email = lower(email)),
  role        text not null check (role in ('viewer', 'editor', 'admin')),
  invited_by  uuid default auth.uid(),
  invited_at  timestamptz not null default now()
);
alter table public.member_invites enable row level security;
create policy read on public.member_invites for select to authenticated using (public.is_admin());
grant select on public.member_invites to authenticated;     -- changes only through the functions below
create trigger audit after insert or update or delete on public.member_invites
  for each row execute function public.log_change('email', 'role');

-- Add an existing user, or invite an email that hasn't signed in yet. Returns 'added' or 'invited'.
drop function public.set_member(text, text);
create function public.set_member(p_email text, p_role text) returns text
  language plpgsql security definer set search_path = public as $$
declare v_email text := lower(trim(p_email));
begin
  if not public.is_admin() then raise exception 'Only admins can manage access' using errcode = '42501'; end if;
  if p_role not in ('viewer', 'editor', 'admin') then raise exception 'Role must be viewer, editor or admin'; end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception '"%" is not an email address', p_email; end if;
  perform public.set_via('radar');
  insert into members (user_id, email, role)
  select id, email, p_role from auth.users where lower(email) = v_email
  on conflict (user_id) do update set role = excluded.role;
  if found then
    delete from member_invites where email = v_email;
    return 'added';
  end if;
  insert into member_invites (email, role) values (v_email, p_role)
  on conflict (email) do update set role = excluded.role, invited_by = auth.uid(), invited_at = now();
  return 'invited';
end $$;

create or replace function public.remove_member(p_email text) returns void
  language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Only admins can manage access' using errcode = '42501'; end if;
  if lower(trim(p_email)) = lower(auth.jwt() ->> 'email') then raise exception 'You cannot remove yourself'; end if;
  perform public.set_via('radar');
  delete from members where lower(email) = lower(trim(p_email));
  delete from member_invites where email = lower(trim(p_email));
end $$;

-- whoami() now also accepts a pending invitation on first sign-in (confirmed email only).
create or replace function public.whoami() returns jsonb
  language plpgsql security definer set search_path = public as $$
declare v_role text; v_inv member_invites;
begin
  if auth.uid() is null then return null; end if;
  select role into v_role from members where user_id = auth.uid();
  if v_role is null then
    select i.* into v_inv from member_invites i
      join auth.users u on lower(u.email) = i.email
     where u.id = auth.uid() and u.email_confirmed_at is not null;
    if found then
      perform set_config('app.via', 'invite', true);
      insert into members (user_id, email, role)
      select id, email, v_inv.role from auth.users where id = auth.uid();
      delete from member_invites where email = v_inv.email;
      v_role := v_inv.role;
    end if;
  end if;
  return jsonb_build_object('email', auth.jwt() ->> 'email', 'role', v_role);
end $$;

revoke execute on function public.set_member(text, text), public.remove_member(text), public.whoami() from public, anon;
grant execute on function public.set_member(text, text), public.remove_member(text), public.whoami() to authenticated;
