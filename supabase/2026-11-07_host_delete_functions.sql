-- Steaksgiving: the two host-link functions that remove RSVP rows.
-- The rest of the host-link migration was applied in pieces on 2026-11-07;
-- these two contain DELETE statements, so Supabase needs you to approve them.
-- Paste into the Supabase SQL editor (project steaksgiving-bingo) and press Run.

begin;

-- A host removes someone's RSVP from the host panel (can't remove the last host).
create or replace function public.host_rsvp_delete(p_token uuid, p_id uuid) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  if not is_host_token(p_token) then raise exception 'Hosts only'; end if;
  if (select is_host from rsvps where id = p_id) and (select count(*) from rsvps where is_host) <= 1 then
    raise exception 'That''s the last host. Make someone else a host first.';
  end if;
  delete from rsvps where id = p_id;
end $$;
grant execute on function public.host_rsvp_delete(uuid, uuid) to anon, authenticated;

-- A guest cancels their own RSVP (the last host can't).
create or replace function public.rsvp_cancel(p_token uuid) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  if is_host_token(p_token) and (select count(*) from rsvps where is_host) <= 1 then
    raise exception 'You''re the last host. Make someone else a host first.';
  end if;
  delete from rsvps where token = p_token;
end $$;

commit;
