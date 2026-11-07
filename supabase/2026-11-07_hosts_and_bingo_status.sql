-- Steaksgiving: hosts via RSVP links, retire the shared PIN, Bingo start/close state.
-- Paste into the Supabase SQL editor (project steaksgiving-bingo) and press Run.
-- Runs as one transaction: if any statement fails, nothing changes.

begin;

-- 1. New columns
alter table rsvps add column if not exists is_host boolean not null default false;
alter table game add column if not exists status text not null default 'waiting';
alter table game drop constraint if exists game_status_chk;
alter table game add constraint game_status_chk check (status in ('waiting','open','ended'));

-- 2. Internal helper: is this RSVP token a host?
create or replace function public.is_host_token(p_token uuid) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select coalesce((select is_host from rsvps where token = p_token), false);
$$;
revoke execute on function public.is_host_token(uuid) from public, anon, authenticated;

-- 3. Public guest list: read-only, no host-only fields
drop view if exists public.rsvps_public;
create view public.rsvps_public as
  select id, name, guests, dishes, created_at, updated_at, is_host from rsvps;
revoke all on public.rsvps_public from public, anon, authenticated;
grant select on public.rsvps_public to anon, authenticated;

-- 4. Retire the shared PIN
drop function if exists public.host_new_round(text);
drop function if exists public.host_next_call(text);
drop function if exists public.host_remove_player(text, uuid);
drop function if exists public.host_resolve_claim(text, uuid, text);
drop function if exists public.host_rsvp_arrived(text, uuid, boolean);
drop function if exists public.host_rsvp_delete(text, uuid);
drop function if exists public.host_rsvp_save(text, uuid, text, jsonb, jsonb, text);
drop function if exists public.host_undo_call(text);
drop function if exists public.check_pin(text);
delete from config where key = 'host_pin';

-- 5. Host functions keyed by RSVP token
create or replace function public.host_check(p_token uuid) returns boolean
language sql stable security definer set search_path to 'public' as $$ select is_host_token(p_token); $$;

create or replace function public.host_list(p_token uuid) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not is_host_token(p_token) then raise exception 'Hosts only'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'arrived', arrived, 'host_note', host_note)) from rsvps), '[]'::jsonb);
end $$;

create or replace function public.host_rsvp_save(p_token uuid, p_id uuid, p_name text, p_guests jsonb, p_dishes jsonb, p_host_note text) returns uuid
language plpgsql security definer set search_path to 'public' as $$
declare rid uuid;
begin
  if not is_host_token(p_token) then raise exception 'Hosts only'; end if;
  if p_name is null or btrim(p_name) = '' then raise exception 'Name required'; end if;
  if p_id is not null then
    update rsvps set name = btrim(p_name), guests = coalesce(p_guests,'[]'::jsonb), dishes = coalesce(p_dishes,'[]'::jsonb),
      host_note = nullif(btrim(coalesce(p_host_note,'')),''), updated_at = now()
    where id = p_id returning id into rid;
  end if;
  if rid is null then
    insert into rsvps (name, guests, dishes, host_note)
    values (btrim(p_name), coalesce(p_guests,'[]'::jsonb), coalesce(p_dishes,'[]'::jsonb), nullif(btrim(coalesce(p_host_note,'')),''))
    returning id into rid;
  end if;
  return rid;
end $$;

create or replace function public.host_rsvp_delete(p_token uuid, p_id uuid) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  if not is_host_token(p_token) then raise exception 'Hosts only'; end if;
  if (select is_host from rsvps where id = p_id) and (select count(*) from rsvps where is_host) <= 1 then
    raise exception 'That''s the last host. Make someone else a host first.';
  end if;
  delete from rsvps where id = p_id;
end $$;

create or replace function public.host_rsvp_arrived(p_token uuid, p_id uuid, p_arrived boolean) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  if not is_host_token(p_token) then raise exception 'Hosts only'; end if;
  update rsvps set arrived = p_arrived where id = p_id;
end $$;

create or replace function public.host_set_host(p_token uuid, p_id uuid, p_is_host boolean) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  if not is_host_token(p_token) then raise exception 'Hosts only'; end if;
  if not p_is_host and (select is_host from rsvps where id = p_id) and (select count(*) from rsvps where is_host) <= 1 then
    raise exception 'That''s the last host. Make someone else a host first.';
  end if;
  update rsvps set is_host = p_is_host, updated_at = now() where id = p_id;
end $$;

create or replace function public.host_bingo_status(p_token uuid, p_status text) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  if not is_host_token(p_token) then raise exception 'Hosts only'; end if;
  if p_status not in ('open','ended','waiting') then raise exception 'Bad status'; end if;
  update game set status = p_status, updated_at = now() where id = 1;
end $$;

create or replace function public.host_next_call(p_token uuid) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare g game; pick record; c jsonb;
begin
  if not is_host_token(p_token) then raise exception 'Hosts only'; end if;
  select * into g from game where id = 1 for update;
  select d.steak, d.topping into pick from deck d
   where not exists (select 1 from jsonb_array_elements(g.calls) e where e->>'steak' = d.steak and e->>'topping' = d.topping)
   order by random() limit 1;
  if pick is null then return null; end if;
  c := jsonb_build_object('steak', pick.steak, 'topping', pick.topping, 'n', jsonb_array_length(g.calls) + 1);
  update game set calls = calls || c, updated_at = now() where id = 1;
  return c;
end $$;

create or replace function public.host_undo_call(p_token uuid) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  if not is_host_token(p_token) then raise exception 'Hosts only'; end if;
  update game set calls = case when jsonb_array_length(calls) > 0 then calls - (jsonb_array_length(calls) - 1) else calls end,
    updated_at = now() where id = 1;
end $$;

create or replace function public.host_new_round(p_token uuid) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  if not is_host_token(p_token) then raise exception 'Hosts only'; end if;
  update game set round = round + 1, calls = '[]'::jsonb, winner = null, updated_at = now() where id = 1;
end $$;

create or replace function public.host_remove_player(p_token uuid, p_player uuid) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  if not is_host_token(p_token) then raise exception 'Hosts only'; end if;
  update players set removed = true where id = p_player;
end $$;

create or replace function public.host_resolve_claim(p_token uuid, p_claim uuid, p_status text) returns void
language plpgsql security definer set search_path to 'public' as $$
declare cl claims;
begin
  if not is_host_token(p_token) then raise exception 'Hosts only'; end if;
  update claims set status = p_status where id = p_claim returning * into cl;
  if p_status = 'verified' then update game set winner = cl.name, updated_at = now() where id = 1; end if;
end $$;

grant execute on function public.host_check(uuid), public.host_list(uuid),
  public.host_rsvp_save(uuid,uuid,text,jsonb,jsonb,text), public.host_rsvp_delete(uuid,uuid),
  public.host_rsvp_arrived(uuid,uuid,boolean), public.host_set_host(uuid,uuid,boolean),
  public.host_bingo_status(uuid,text), public.host_next_call(uuid), public.host_undo_call(uuid),
  public.host_new_round(uuid), public.host_remove_player(uuid,uuid), public.host_resolve_claim(uuid,uuid,text)
  to anon, authenticated;

-- 6. A host can't cancel their own RSVP if they're the last host
create or replace function public.rsvp_cancel(p_token uuid) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  if is_host_token(p_token) and (select count(*) from rsvps where is_host) <= 1 then
    raise exception 'You''re the last host. Make someone else a host first.';
  end if;
  delete from rsvps where token = p_token;
end $$;

-- 7. Bingo boards and claims only while Bingo is open
drop policy if exists "players insert" on players;
create policy "players insert" on players for insert to anon, authenticated
  with check (exists (select 1 from game where id = 1 and status = 'open'));
drop policy if exists "claims insert" on claims;
create policy "claims insert" on claims for insert to anon, authenticated
  with check (status = 'pending' and exists (select 1 from game where id = 1 and status = 'open'));

-- 8. Live-update signal for the RSVP page (no RSVP data in it)
create table if not exists public.rsvp_ping (id int primary key default 1, at timestamptz not null default now());
insert into public.rsvp_ping (id) values (1) on conflict (id) do nothing;
alter table public.rsvp_ping enable row level security;
drop policy if exists "rsvp_ping read" on public.rsvp_ping;
create policy "rsvp_ping read" on public.rsvp_ping for select to anon, authenticated using (true);
grant select on public.rsvp_ping to anon, authenticated;
create or replace function public.rsvp_ping_touch() returns trigger
language plpgsql security definer set search_path to 'public' as $$
begin update rsvp_ping set at = now() where id = 1; return null; end $$;
drop trigger if exists rsvps_ping on rsvps;
create trigger rsvps_ping after insert or update or delete on rsvps for each statement execute function public.rsvp_ping_touch();
do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and tablename='rsvp_ping') then
    alter publication supabase_realtime add table public.rsvp_ping;
  end if;
end $$;

-- 9. Clean slate for the party
delete from claims;
delete from players;
update game set round = 1, calls = '[]'::jsonb, winner = null, status = 'waiting', updated_at = now() where id = 1;

commit;
