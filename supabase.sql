-- Heuhaufen: Bestenliste für das Tagesrätsel
-- Einmal komplett im Supabase "SQL Editor" einfügen und auf "Run" klicken.
-- Das Skript kann gefahrlos mehrfach ausgeführt werden.

create table if not exists public.scores (
  id          uuid primary key default gen_random_uuid(),
  day         date not null,
  player_id   text not null check (char_length(player_id) between 8 and 64),
  secret      uuid not null default gen_random_uuid(),
  name        text check (name ~ '^[A-Z0-9ÄÖÜ]{3}$'),
  score       integer not null default 0 check (score between 0 and 500),
  tiers       smallint[] not null default '{}',
  status      text not null default 'playing' check (status in ('playing', 'done')),
  started_at  timestamptz not null default now(),
  done_at     timestamptz,
  unique (day, player_id)
);

-- Niemand darf direkt auf die Tabelle zugreifen – nur über die Funktionen unten.
alter table public.scores enable row level security;
revoke all on table public.scores from anon, authenticated;

-- Tagesrätsel starten: ein Eintrag pro Gerät und Tag.
create or replace function public.start_daily(p_day date, p_player text)
returns table (id uuid, secret uuid)
language plpgsql security definer set search_path = public
as $$
#variable_conflict use_column
begin
  if p_day is distinct from (now() at time zone 'Europe/Berlin')::date then
    raise exception 'wrong_day';
  end if;
  if p_player is null or char_length(p_player) not between 8 and 64 then
    raise exception 'bad_player';
  end if;
  if exists (select 1 from public.scores s where s.day = p_day and s.player_id = p_player) then
    raise exception 'already_played';
  end if;
  return query
    insert into public.scores (day, player_id) values (p_day, p_player)
    returning scores.id, scores.secret;
end;
$$;

-- Fortschritt speichern. Die Punkte werden hier aus den Stufen berechnet.
-- Stufen: -1 = keine Punkte, 0..4 = Heuballen, Strohhalm, Ähre, Kornblume, Nadel.
create or replace function public.save_daily(p_id uuid, p_secret uuid, p_tiers smallint[], p_done boolean)
returns integer
language plpgsql security definer set search_path = public
as $$
#variable_conflict use_column
declare
  v_score integer := 0;
  v_tier  smallint;
  v_pts   integer[] := array[10, 30, 55, 80, 100];
begin
  if p_tiers is null or coalesce(array_length(p_tiers, 1), 0) > 5 then
    raise exception 'bad_tiers';
  end if;
  foreach v_tier in array p_tiers loop
    if v_tier is null or v_tier < -1 or v_tier > 4 then
      raise exception 'bad_tiers';
    end if;
    if v_tier >= 0 then
      v_score := v_score + v_pts[v_tier + 1];
    end if;
  end loop;

  update public.scores s
     set tiers   = p_tiers,
         score   = v_score,
         status  = case when p_done then 'done' else s.status end,
         done_at = case when p_done and s.done_at is null then now() else s.done_at end
   where s.id = p_id
     and s.secret = p_secret
     and s.status = 'playing'
     and coalesce(array_length(s.tiers, 1), 0) <= coalesce(array_length(p_tiers, 1), 0);

  if not found then
    raise exception 'not_allowed';
  end if;
  return v_score;
end;
$$;

-- Kürzel eintragen (genau einmal).
create or replace function public.set_name(p_id uuid, p_secret uuid, p_name text)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if p_name is null or p_name !~ '^[A-Z0-9ÄÖÜ]{3}$' then
    raise exception 'bad_name';
  end if;
  update public.scores s
     set name = p_name
   where s.id = p_id and s.secret = p_secret and s.name is null;
  if not found then
    raise exception 'not_allowed';
  end if;
end;
$$;

-- Bestenliste eines Tages lesen (nur Einträge mit Kürzel, ohne Geheimnisse).
drop function if exists public.get_board(date);
create function public.get_board(p_day date)
returns table (player_id text, name text, score integer, tiers smallint[], status text, sort_time bigint)
language sql security definer set search_path = public stable
as $$
  select s.player_id, s.name, s.score, s.tiers, s.status,
         (extract(epoch from coalesce(s.done_at, s.started_at)) * 1000)::bigint
    from public.scores s
   where s.day = p_day and s.name is not null
   order by s.score desc, coalesce(s.done_at, s.started_at) asc
   limit 500;
$$;

revoke all on function public.start_daily(date, text) from public;
revoke all on function public.save_daily(uuid, uuid, smallint[], boolean) from public;
revoke all on function public.set_name(uuid, uuid, text) from public;
revoke all on function public.get_board(date) from public;
grant execute on function public.start_daily(date, text) to anon, authenticated;
grant execute on function public.save_daily(uuid, uuid, smallint[], boolean) to anon, authenticated;
grant execute on function public.set_name(uuid, uuid, text) to anon, authenticated;
grant execute on function public.get_board(date) to anon, authenticated;
