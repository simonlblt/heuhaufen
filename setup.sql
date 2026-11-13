-- Heuhaufen: komplette Datenbank-Einrichtung in EINEM Skript
--
-- So geht's: Alles markieren und kopieren, in Supabase links auf "SQL Editor" gehen,
-- einfügen und unten rechts auf "Run" klicken. Erwartet wird "Success. No rows returned".
--
-- Das Skript richtet alles ein, was die Seite braucht – und bringt eine bestehende
-- Datenbank auf den neuesten Stand. Es kann gefahrlos beliebig oft ausgeführt werden;
-- vorhandene Profile, Ergebnisse und Duelle bleiben erhalten.
-- Nach jedem Update der Seite einfach dieses eine Skript noch einmal laufen lassen.
--
-- Aufbau: Die Teile bauen aufeinander auf. Spätere Teile ersetzen einzelne Funktionen
-- aus früheren Teilen durch die aktuelle Fassung – es gilt immer die letzte.


-- ============================================================
-- Teil 1 · Tagesrätsel und Bestenliste
-- ============================================================

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
-- Stufen: -1 = keine Punkte, 0..4 = Heuballen, Strohhalm, Maus, Kleeblatt, Nadel.
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


-- ============================================================
-- Teil 2 · Duell per Link
-- ============================================================

-- Öffentliche Spieler-Kennung (aus der geheimen Geräte-Kennung abgeleitet, nicht zurückrechenbar).
create or replace function public.hh_pid(p text)
returns text
language sql immutable
as $$ select left(md5('heuhaufen:' || coalesce(p, '')), 12) $$;

create table if not exists public.duels (
  code        text primary key check (code ~ '^[A-Z2-9]{5}$'),
  created_at  timestamptz not null default now(),
  qids        text[] not null check (array_length(qids, 1) = 5),
  a_player    text not null check (char_length(a_player) between 8 and 64),
  a_secret    uuid not null default gen_random_uuid(),
  a_name      text not null check (a_name ~ '^[A-Z0-9ÄÖÜ]{3}$'),
  a_tiers     smallint[] not null default '{}',
  a_answers   text[] not null default '{}',
  a_score     integer not null default 0,
  a_status    text not null default 'playing' check (a_status in ('playing', 'done')),
  a_done_at   timestamptz,
  b_player    text check (char_length(b_player) between 8 and 64),
  b_secret    uuid,
  b_name      text check (b_name ~ '^[A-Z0-9ÄÖÜ]{3}$'),
  b_tiers     smallint[] not null default '{}',
  b_answers   text[] not null default '{}',
  b_score     integer not null default 0,
  b_status    text check (b_status in ('playing', 'done')),
  b_done_at   timestamptz
);
create index if not exists duels_a_player_idx on public.duels (a_player, created_at);

-- Niemand darf direkt auf die Tabelle zugreifen – nur über die Funktionen unten.
alter table public.duels enable row level security;
revoke all on table public.duels from anon, authenticated;

-- Duell anlegen: erzeugt einen 5-stelligen Code. Höchstens 30 neue Duelle pro Gerät und Tag.
create or replace function public.create_duel(p_player text, p_name text, p_qids text[])
returns table (code text, secret uuid)
language plpgsql security definer set search_path = public
as $$
#variable_conflict use_column
declare
  v_alpha text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_code  text;
  v_try   integer := 0;
  v_q     text;
begin
  if p_player is null or char_length(p_player) not between 8 and 64 then
    raise exception 'bad_player';
  end if;
  if p_name is null or p_name !~ '^[A-Z0-9ÄÖÜ]{3}$' then
    raise exception 'bad_name';
  end if;
  if p_qids is null or coalesce(array_length(p_qids, 1), 0) <> 5 then
    raise exception 'bad_questions';
  end if;
  foreach v_q in array p_qids loop
    if v_q is null or v_q !~ '^[a-z0-9]{1,12}$' then
      raise exception 'bad_questions';
    end if;
  end loop;
  if (select count(*) from public.duels d where d.a_player = p_player and d.created_at > now() - interval '1 day') >= 30 then
    raise exception 'too_many';
  end if;
  loop
    v_code := '';
    for i in 1..5 loop
      v_code := v_code || substr(v_alpha, 1 + floor(random() * length(v_alpha))::int, 1);
    end loop;
    begin
      return query
        insert into public.duels (code, qids, a_player, a_name)
        values (v_code, p_qids, p_player, p_name)
        returning duels.code, duels.a_secret;
      return;
    exception when unique_violation then
      v_try := v_try + 1;
      if v_try > 10 then
        raise exception 'no_code';
      end if;
    end;
  end loop;
end;
$$;

-- Duell annehmen: genau ein Gegner pro Duell.
create or replace function public.join_duel(p_code text, p_player text, p_name text)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  d        public.duels;
  v_secret uuid := gen_random_uuid();
begin
  if p_player is null or char_length(p_player) not between 8 and 64 then
    raise exception 'bad_player';
  end if;
  if p_name is null or p_name !~ '^[A-Z0-9ÄÖÜ]{3}$' then
    raise exception 'bad_name';
  end if;
  select * into d from public.duels x where x.code = upper(p_code) for update;
  if not found then
    raise exception 'not_found';
  end if;
  if d.a_player = p_player then
    raise exception 'own_duel';
  end if;
  if d.b_player is not null then
    if d.b_player = p_player then
      raise exception 'already_joined';
    end if;
    raise exception 'taken';
  end if;
  update public.duels x
     set b_player = p_player, b_name = p_name, b_secret = v_secret, b_status = 'playing'
   where x.code = d.code;
  return v_secret;
end;
$$;

-- Fortschritt speichern. Die Punkte werden hier aus den Stufen berechnet.
-- Stufen: -1 = keine Punkte, 0..4 = Heuballen, Strohhalm, Maus, Kleeblatt, Nadel.
create or replace function public.save_duel(p_code text, p_secret uuid, p_tiers smallint[], p_answers text[], p_done boolean)
returns integer
language plpgsql security definer set search_path = public
as $$
declare
  d       public.duels;
  v_n     integer := coalesce(array_length(p_tiers, 1), 0);
  v_score integer := 0;
  v_tier  smallint;
  v_ans   text;
  v_pts   integer[] := array[10, 30, 55, 80, 100];
begin
  if p_tiers is null or p_answers is null or v_n > 5 or coalesce(array_length(p_answers, 1), 0) <> v_n then
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
  foreach v_ans in array p_answers loop
    if v_ans is null or char_length(v_ans) > 60 then
      raise exception 'bad_answers';
    end if;
  end loop;

  select * into d from public.duels x where x.code = upper(p_code) for update;
  if not found then
    raise exception 'not_found';
  end if;

  if d.a_secret = p_secret then
    if d.a_status <> 'playing' or coalesce(array_length(d.a_tiers, 1), 0) > v_n then
      raise exception 'not_allowed';
    end if;
    update public.duels x
       set a_tiers = p_tiers, a_answers = p_answers, a_score = v_score,
           a_status = case when p_done then 'done' else 'playing' end,
           a_done_at = case when p_done then now() else null end
     where x.code = d.code;
  elsif d.b_secret is not null and d.b_secret = p_secret then
    if d.b_status <> 'playing' or coalesce(array_length(d.b_tiers, 1), 0) > v_n then
      raise exception 'not_allowed';
    end if;
    update public.duels x
       set b_tiers = p_tiers, b_answers = p_answers, b_score = v_score,
           b_status = case when p_done then 'done' else 'playing' end,
           b_done_at = case when p_done then now() else null end
     where x.code = d.code;
  else
    raise exception 'not_allowed';
  end if;
  return v_score;
end;
$$;

-- Duell lesen. Die Antworten des Gegners gibt es erst, wenn beide fertig sind.
create or replace function public.get_duel(p_code text, p_player text)
returns json
language plpgsql security definer set search_path = public stable
as $$
declare
  d      public.duels;
  v_role text;
  v_fin  boolean;
begin
  select * into d from public.duels x where x.code = upper(p_code);
  if not found then
    return null;
  end if;
  v_role := case when d.a_player = p_player then 'a'
                 when d.b_player is not null and d.b_player = p_player then 'b'
                 else null end;
  v_fin := d.a_status = 'done' and coalesce(d.b_status, '') = 'done';
  return json_build_object(
    'code', d.code,
    'qids', d.qids,
    'role', v_role,
    'final', v_fin,
    'a', json_build_object(
      'name', d.a_name, 'pid', public.hh_pid(d.a_player), 'status', d.a_status, 'n', coalesce(array_length(d.a_tiers, 1), 0),
      'tiers',   case when v_fin or v_role = 'a' then to_json(d.a_tiers) end,
      'answers', case when v_fin or v_role = 'a' then to_json(d.a_answers) end,
      'score',   case when v_fin or v_role = 'a' then d.a_score end),
    'b', case when d.b_name is null then null else json_build_object(
      'name', d.b_name, 'pid', public.hh_pid(d.b_player), 'status', d.b_status, 'n', coalesce(array_length(d.b_tiers, 1), 0),
      'tiers',   case when v_fin or v_role = 'b' then to_json(d.b_tiers) end,
      'answers', case when v_fin or v_role = 'b' then to_json(d.b_answers) end,
      'score',   case when v_fin or v_role = 'b' then d.b_score end) end
  );
end;
$$;

revoke all on function public.hh_pid(text) from public, anon, authenticated;
revoke all on function public.create_duel(text, text, text[]) from public;
revoke all on function public.join_duel(text, text, text) from public;
revoke all on function public.save_duel(text, uuid, smallint[], text[], boolean) from public;
revoke all on function public.get_duel(text, text) from public;
grant execute on function public.create_duel(text, text, text[]) to anon, authenticated;
grant execute on function public.join_duel(text, text, text) to anon, authenticated;
grant execute on function public.save_duel(text, uuid, smallint[], text[], boolean) to anon, authenticated;
grant execute on function public.get_duel(text, text) to anon, authenticated;


-- ============================================================
-- Teil 3 · Spielerprofile und Match-Historie
-- ============================================================

-- Öffentliche Spieler-Kennung. Sie wird aus der geheimen Geräte-Kennung abgeleitet
-- und lässt sich nicht zurückrechnen – nur sie taucht in Links und Listen auf.
create or replace function public.hh_pid(p text)
returns text
language sql immutable
as $$ select left(md5('heuhaufen:' || coalesce(p, '')), 12) $$;

-- Ein Duell auswerten – genau wie im Spiel: Pro Frage gewinnt die seltenere Antwort,
-- gleiche Antworten zählen für keinen, bei gleich vielen Fragen entscheiden die Punkte.
create or replace function public.hh_duel_outcome(d public.duels)
returns table (wa integer, wb integer, sa integer, sb integer, winner text)
language plpgsql immutable
as $$
declare
  v_pts integer[] := array[10, 30, 55, 80, 100];
  ta integer;
  tb integer;
  aa text;
  ab text;
begin
  wa := 0; wb := 0; sa := 0; sb := 0;
  for i in 1..5 loop
    ta := coalesce(d.a_tiers[i], -1);
    tb := coalesce(d.b_tiers[i], -1);
    aa := coalesce(d.a_answers[i], '');
    ab := coalesce(d.b_answers[i], '');
    if ta >= 0 and tb >= 0 and aa <> '' and lower(aa) = lower(ab) then
      continue;
    end if;
    if ta >= 0 then sa := sa + v_pts[ta + 1]; end if;
    if tb >= 0 then sb := sb + v_pts[tb + 1]; end if;
    if ta > tb then wa := wa + 1; elsif tb > ta then wb := wb + 1; end if;
  end loop;
  winner := case when wa > wb then 'a' when wb > wa then 'b'
                 when sa > sb then 'a' when sb > sa then 'b' else null end;
  return next;
end;
$$;

-- Profil lesen: über die öffentliche Kennung (p_pid) oder – ohne sie – das eigene (p_player).
create or replace function public.get_profile(p_pid text, p_player text)
returns json
language plpgsql security definer set search_path = public stable
as $$
declare
  v_player text;
  v_me     boolean;
  v_today  date := (now() at time zone 'Europe/Berlin')::date;
  v_json   json;
begin
  if coalesce(p_pid, '') = '' then
    if p_player is null or char_length(p_player) not between 8 and 64 then
      return null;
    end if;
    v_player := p_player;
  else
    if p_pid !~ '^[0-9a-f]{12}$' then
      return null;
    end if;
    select x.p into v_player from (
      select d.a_player as p from public.duels d where public.hh_pid(d.a_player) = p_pid
      union all
      select d.b_player from public.duels d where d.b_player is not null and public.hh_pid(d.b_player) = p_pid
      union all
      select s.player_id from public.scores s where public.hh_pid(s.player_id) = p_pid
    ) x limit 1;
    if v_player is null then
      return null;
    end if;
  end if;
  v_me := p_player is not null and p_player = v_player;

  with mine as (
    select d.code, d.created_at,
           d.a_player = v_player as is_a,
           (d.a_status = 'done' and coalesce(d.b_status, '') = 'done') as final,
           case when d.a_player = v_player then d.b_name else d.a_name end as opp_name,
           case when d.a_player = v_player
                then case when d.b_player is null then null else public.hh_pid(d.b_player) end
                else public.hh_pid(d.a_player) end as opp_pid,
           case when d.a_player = v_player then d.a_status else d.b_status end as my_status,
           case when d.a_player = v_player then d.b_status else d.a_status end as opp_status,
           case when d.a_player = v_player then d.a_tiers else d.b_tiers end as my_tiers,
           o.wa, o.wb, o.sa, o.sb, o.winner
      from public.duels d
      cross join lateral public.hh_duel_outcome(d) o
     where d.a_player = v_player or d.b_player = v_player
  ), r as (
    select m.*,
           case when not m.final then 'open'
                when m.winner is null then 'draw'
                when (m.winner = 'a') = m.is_a then 'win'
                else 'loss' end as result,
           case when m.is_a then m.wa else m.wb end as my_rounds,
           case when m.is_a then m.wb else m.wa end as opp_rounds,
           case when m.is_a then m.sa else m.sb end as my_pts,
           case when m.is_a then m.sb else m.sa end as opp_pts
      from mine m
  )
  select json_build_object(
    'pid', public.hh_pid(v_player),
    'me', v_me,
    'name', (select x.n from (
        select d.a_name as n, d.created_at as t from public.duels d where d.a_player = v_player
        union all
        select d.b_name, d.created_at from public.duels d where d.b_player = v_player and d.b_name is not null
        union all
        select s.name, s.started_at from public.scores s where s.player_id = v_player and s.name is not null
      ) x order by x.t desc limit 1),
    'since', (select (extract(epoch from min(x.t)) * 1000)::bigint from (
        select d.created_at as t from public.duels d where d.a_player = v_player or d.b_player = v_player
        union all
        select s.started_at from public.scores s where s.player_id = v_player
      ) x),
    'duels', (select json_build_object(
        'played',      count(*) filter (where r.final),
        'wins',        count(*) filter (where r.result = 'win'),
        'losses',      count(*) filter (where r.result = 'loss'),
        'draws',       count(*) filter (where r.result = 'draw'),
        'open',        count(*) filter (where not r.final),
        'rounds_won',  coalesce(sum(r.my_rounds) filter (where r.final), 0),
        'rounds_lost', coalesce(sum(r.opp_rounds) filter (where r.final), 0),
        'avg_pts',     round(avg(r.my_pts) filter (where r.final)),
        'best_pts',    max(r.my_pts) filter (where r.final),
        'needles',     (select count(*) from r r2, unnest(r2.my_tiers) t where t = 4)
      ) from r),
    'history', (select coalesce(json_agg(h order by h.t desc), '[]'::json) from (
        select r.code, (extract(epoch from r.created_at) * 1000)::bigint as t, r.result,
               r.opp_name, r.opp_pid, r.my_status, r.opp_status,
               case when r.final then r.my_rounds end as my_rounds,
               case when r.final then r.opp_rounds end as opp_rounds,
               case when r.final then r.my_pts end as my_pts,
               case when r.final then r.opp_pts end as opp_pts
          from r
         where r.final or v_me
         order by r.created_at desc
         limit 30
      ) h),
    'rivals', (select coalesce(json_agg(x order by x.games desc, x.wins desc), '[]'::json) from (
        select r.opp_pid as pid, max(r.opp_name) as name, count(*) as games,
               count(*) filter (where r.result = 'win') as wins,
               count(*) filter (where r.result = 'loss') as losses
          from r
         where r.final and r.opp_pid is not null
         group by r.opp_pid
         order by count(*) desc
         limit 5
      ) x),
    'daily', (select json_build_object(
        'played', count(*),
        'avg',    round(avg(s.score)),
        'best',   max(s.score),
        'wins',   count(*) filter (where s.name is not null and s.score > 0 and s.score =
                    (select max(s2.score) from public.scores s2 where s2.day = s.day and s2.name is not null)),
        'needles', (select count(*) from public.scores s3, unnest(s3.tiers) t where s3.player_id = v_player and t = 4)
      ) from public.scores s
      where s.player_id = v_player and (s.status = 'done' or s.day < v_today))
  ) into v_json;
  return v_json;
end;
$$;

-- Bestenliste mit öffentlicher Kennung (für Links zum Profil) und "me" für die eigene Zeile.
create or replace function public.get_board2(p_day date, p_player text)
returns table (pid text, me boolean, name text, score integer, tiers smallint[], status text, sort_time bigint)
language sql security definer set search_path = public stable
as $$
  select public.hh_pid(s.player_id), (p_player is not null and s.player_id = p_player),
         s.name, s.score, s.tiers, s.status,
         (extract(epoch from coalesce(s.done_at, s.started_at)) * 1000)::bigint
    from public.scores s
   where s.day = p_day and (s.name is not null or s.player_id = p_player)
   order by s.score desc, coalesce(s.done_at, s.started_at) asc
   limit 500;
$$;

-- Die alte Bestenliste gibt keine geheimen Geräte-Kennungen mehr heraus, nur noch die öffentliche.
create or replace function public.get_board(p_day date)
returns table (player_id text, name text, score integer, tiers smallint[], status text, sort_time bigint)
language sql security definer set search_path = public stable
as $$
  select public.hh_pid(s.player_id), s.name, s.score, s.tiers, s.status,
         (extract(epoch from coalesce(s.done_at, s.started_at)) * 1000)::bigint
    from public.scores s
   where s.day = p_day and s.name is not null
   order by s.score desc, coalesce(s.done_at, s.started_at) asc
   limit 500;
$$;

-- Duell lesen – jetzt mit öffentlicher Kennung beider Spieler (für Links zum Profil).
create or replace function public.get_duel(p_code text, p_player text)
returns json
language plpgsql security definer set search_path = public stable
as $$
declare
  d      public.duels;
  v_role text;
  v_fin  boolean;
begin
  select * into d from public.duels x where x.code = upper(p_code);
  if not found then
    return null;
  end if;
  v_role := case when d.a_player = p_player then 'a'
                 when d.b_player is not null and d.b_player = p_player then 'b'
                 else null end;
  v_fin := d.a_status = 'done' and coalesce(d.b_status, '') = 'done';
  return json_build_object(
    'code', d.code,
    'qids', d.qids,
    'role', v_role,
    'final', v_fin,
    'a', json_build_object(
      'name', d.a_name, 'pid', public.hh_pid(d.a_player), 'status', d.a_status, 'n', coalesce(array_length(d.a_tiers, 1), 0),
      'tiers',   case when v_fin or v_role = 'a' then to_json(d.a_tiers) end,
      'answers', case when v_fin or v_role = 'a' then to_json(d.a_answers) end,
      'score',   case when v_fin or v_role = 'a' then d.a_score end),
    'b', case when d.b_name is null then null else json_build_object(
      'name', d.b_name, 'pid', public.hh_pid(d.b_player), 'status', d.b_status, 'n', coalesce(array_length(d.b_tiers, 1), 0),
      'tiers',   case when v_fin or v_role = 'b' then to_json(d.b_tiers) end,
      'answers', case when v_fin or v_role = 'b' then to_json(d.b_answers) end,
      'score',   case when v_fin or v_role = 'b' then d.b_score end) end
  );
end;
$$;

revoke all on function public.hh_pid(text) from public, anon, authenticated;
revoke all on function public.hh_duel_outcome(public.duels) from public, anon, authenticated;
revoke all on function public.get_profile(text, text) from public;
revoke all on function public.get_board2(date, text) from public;
revoke all on function public.get_board(date) from public;
revoke all on function public.get_duel(text, text) from public;
grant execute on function public.get_profile(text, text) to anon, authenticated;
grant execute on function public.get_board2(date, text) to anon, authenticated;
grant execute on function public.get_board(date) to anon, authenticated;
grant execute on function public.get_duel(text, text) to anon, authenticated;


-- ============================================================
-- Teil 4 · Profile mit Name und Passwort
-- ============================================================

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

-- Konten: Name (2–10 Zeichen, Groß/Klein egal eindeutig), Passwort nur als sicherer Hash.
create table if not exists public.accounts (
  name_key     text primary key,
  name         text not null check (name ~ '^[A-Za-z0-9ÄÖÜäöüß_.-]{2,10}$'),
  pw_hash      text not null,
  player_id    text not null unique check (char_length(player_id) between 8 and 64),
  created_at   timestamptz not null default now(),
  failed       integer not null default 0,
  locked_until timestamptz
);
alter table public.accounts enable row level security;
revoke all on table public.accounts from anon, authenticated;

-- Namen bis 10 Zeichen statt der alten 3-Zeichen-Kürzel (alte Kürzel bleiben gültig).
alter table public.scores drop constraint if exists scores_name_check;
alter table public.scores add constraint scores_name_check check (name ~ '^[A-Za-z0-9ÄÖÜäöüß_.-]{2,10}$');
alter table public.duels drop constraint if exists duels_a_name_check;
alter table public.duels add constraint duels_a_name_check check (a_name ~ '^[A-Za-z0-9ÄÖÜäöüß_.-]{2,10}$');
alter table public.duels drop constraint if exists duels_b_name_check;
alter table public.duels add constraint duels_b_name_check check (b_name ~ '^[A-Za-z0-9ÄÖÜäöüß_.-]{2,10}$');

-- Profil erstellen. Das Gerät behält seine Kennung – bisherige Spiele gehören dann zum Profil.
create or replace function public.register(p_player text, p_name text, p_password text)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
begin
  if p_player is null or char_length(p_player) not between 8 and 64 then
    raise exception 'bad_player';
  end if;
  if p_name is null or p_name !~ '^[A-Za-z0-9ÄÖÜäöüß_.-]{2,10}$' then
    raise exception 'bad_name';
  end if;
  if p_password is null or char_length(p_password) not between 6 and 72 then
    raise exception 'bad_password';
  end if;
  if exists (select 1 from public.accounts k where k.name_key = lower(p_name)) then
    raise exception 'name_taken';
  end if;
  if exists (select 1 from public.accounts k where k.player_id = p_player) then
    raise exception 'device_has_account';
  end if;
  insert into public.accounts (name_key, name, pw_hash, player_id)
  values (lower(p_name), p_name, crypt(p_password, gen_salt('bf', 8)), p_player);
  return json_build_object('name', p_name, 'pid', public.hh_pid(p_player));
end;
$$;

-- Anmelden. Nach 8 falschen Versuchen ist das Profil 15 Minuten gesperrt.
create or replace function public.login(p_name text, p_password text)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare
  k public.accounts;
begin
  select * into k from public.accounts x where x.name_key = lower(coalesce(p_name, '')) for update;
  if not found then
    perform pg_sleep(0.3);
    return json_build_object('ok', false, 'error', 'wrong_login');
  end if;
  if k.locked_until is not null and k.locked_until > now() then
    return json_build_object('ok', false, 'error', 'locked', 'wait', ceil(extract(epoch from k.locked_until - now()) / 60));
  end if;
  if p_password is null or k.pw_hash <> crypt(p_password, k.pw_hash) then
    update public.accounts x
       set failed = case when k.failed + 1 >= 8 then 0 else k.failed + 1 end,
           locked_until = case when k.failed + 1 >= 8 then now() + interval '15 minutes' else null end
     where x.name_key = k.name_key;
    return json_build_object('ok', false, 'error', 'wrong_login');
  end if;
  update public.accounts x set failed = 0, locked_until = null where x.name_key = k.name_key;
  return json_build_object('ok', true, 'player', k.player_id, 'name', k.name, 'pid', public.hh_pid(k.player_id));
end;
$$;

-- Tagesrätsel nur mit Profil.
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
  if not exists (select 1 from public.accounts k where k.player_id = p_player) then
    raise exception 'need_account';
  end if;
  if exists (select 1 from public.scores s where s.day = p_day and s.player_id = p_player) then
    raise exception 'already_played';
  end if;
  return query
    insert into public.scores (day, player_id) values (p_day, p_player)
    returning scores.id, scores.secret;
end;
$$;

-- Name in der Bestenliste: kommt immer aus dem Profil (niemand kann sich als jemand anderes ausgeben).
create or replace function public.set_name(p_id uuid, p_secret uuid, p_name text)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_player text;
  v_name   text;
begin
  select s.player_id into v_player from public.scores s where s.id = p_id and s.secret = p_secret;
  if not found then
    raise exception 'not_allowed';
  end if;
  select k.name into v_name from public.accounts k where k.player_id = v_player;
  if v_name is null then
    raise exception 'need_account';
  end if;
  update public.scores s set name = v_name where s.id = p_id and s.secret = p_secret and s.name is null;
end;
$$;

-- Duell anlegen: Name kommt aus dem Profil.
create or replace function public.create_duel(p_player text, p_name text, p_qids text[])
returns table (code text, secret uuid)
language plpgsql security definer set search_path = public
as $$
#variable_conflict use_column
declare
  v_alpha text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_code  text;
  v_try   integer := 0;
  v_q     text;
  v_name  text;
begin
  if p_player is null or char_length(p_player) not between 8 and 64 then
    raise exception 'bad_player';
  end if;
  select k.name into v_name from public.accounts k where k.player_id = p_player;
  if v_name is null then
    raise exception 'need_account';
  end if;
  if p_qids is null or coalesce(array_length(p_qids, 1), 0) <> 5 then
    raise exception 'bad_questions';
  end if;
  foreach v_q in array p_qids loop
    if v_q is null or v_q !~ '^[a-z0-9]{1,12}$' then
      raise exception 'bad_questions';
    end if;
  end loop;
  if (select count(*) from public.duels d where d.a_player = p_player and d.created_at > now() - interval '1 day') >= 30 then
    raise exception 'too_many';
  end if;
  loop
    v_code := '';
    for i in 1..5 loop
      v_code := v_code || substr(v_alpha, 1 + floor(random() * length(v_alpha))::int, 1);
    end loop;
    begin
      return query
        insert into public.duels (code, qids, a_player, a_name)
        values (v_code, p_qids, p_player, v_name)
        returning duels.code, duels.a_secret;
      return;
    exception when unique_violation then
      v_try := v_try + 1;
      if v_try > 10 then
        raise exception 'no_code';
      end if;
    end;
  end loop;
end;
$$;

-- Duell annehmen: Name kommt aus dem Profil.
create or replace function public.join_duel(p_code text, p_player text, p_name text)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  d        public.duels;
  v_name   text;
  v_secret uuid := gen_random_uuid();
begin
  if p_player is null or char_length(p_player) not between 8 and 64 then
    raise exception 'bad_player';
  end if;
  select k.name into v_name from public.accounts k where k.player_id = p_player;
  if v_name is null then
    raise exception 'need_account';
  end if;
  select * into d from public.duels x where x.code = upper(p_code) for update;
  if not found then
    raise exception 'not_found';
  end if;
  if d.a_player = p_player then
    raise exception 'own_duel';
  end if;
  if d.b_player is not null then
    if d.b_player = p_player then
      raise exception 'already_joined';
    end if;
    raise exception 'taken';
  end if;
  update public.duels x
     set b_player = p_player, b_name = v_name, b_secret = v_secret, b_status = 'playing'
   where x.code = d.code;
  return v_secret;
end;
$$;

-- Profil lesen – Name und "dabei seit" kommen jetzt aus dem Konto.
create or replace function public.get_profile(p_pid text, p_player text)
returns json
language plpgsql security definer set search_path = public stable
as $$
declare
  v_player text;
  v_me     boolean;
  v_today  date := (now() at time zone 'Europe/Berlin')::date;
  v_json   json;
begin
  if coalesce(p_pid, '') = '' then
    if p_player is null or char_length(p_player) not between 8 and 64 then
      return null;
    end if;
    v_player := p_player;
  else
    if p_pid !~ '^[0-9a-f]{12}$' then
      return null;
    end if;
    select x.p into v_player from (
      select d.a_player as p from public.duels d where public.hh_pid(d.a_player) = p_pid
      union all
      select d.b_player from public.duels d where d.b_player is not null and public.hh_pid(d.b_player) = p_pid
      union all
      select s.player_id from public.scores s where public.hh_pid(s.player_id) = p_pid
      union all
      select k.player_id from public.accounts k where public.hh_pid(k.player_id) = p_pid
    ) x limit 1;
    if v_player is null then
      return null;
    end if;
  end if;
  v_me := p_player is not null and p_player = v_player;

  with mine as (
    select d.code, d.created_at,
           d.a_player = v_player as is_a,
           (d.a_status = 'done' and coalesce(d.b_status, '') = 'done') as final,
           case when d.a_player = v_player then d.b_name else d.a_name end as opp_name,
           case when d.a_player = v_player
                then case when d.b_player is null then null else public.hh_pid(d.b_player) end
                else public.hh_pid(d.a_player) end as opp_pid,
           case when d.a_player = v_player then d.a_status else d.b_status end as my_status,
           case when d.a_player = v_player then d.b_status else d.a_status end as opp_status,
           case when d.a_player = v_player then d.a_tiers else d.b_tiers end as my_tiers,
           o.wa, o.wb, o.sa, o.sb, o.winner
      from public.duels d
      cross join lateral public.hh_duel_outcome(d) o
     where d.a_player = v_player or d.b_player = v_player
  ), r as (
    select m.*,
           case when not m.final then 'open'
                when m.winner is null then 'draw'
                when (m.winner = 'a') = m.is_a then 'win'
                else 'loss' end as result,
           case when m.is_a then m.wa else m.wb end as my_rounds,
           case when m.is_a then m.wb else m.wa end as opp_rounds,
           case when m.is_a then m.sa else m.sb end as my_pts,
           case when m.is_a then m.sb else m.sa end as opp_pts
      from mine m
  )
  select json_build_object(
    'pid', public.hh_pid(v_player),
    'me', v_me,
    'account', exists (select 1 from public.accounts k where k.player_id = v_player),
    'name', coalesce((select k.name from public.accounts k where k.player_id = v_player), (select x.n from (
        select d.a_name as n, d.created_at as t from public.duels d where d.a_player = v_player
        union all
        select d.b_name, d.created_at from public.duels d where d.b_player = v_player and d.b_name is not null
        union all
        select s.name, s.started_at from public.scores s where s.player_id = v_player and s.name is not null
      ) x order by x.t desc limit 1)),
    'since', (select (extract(epoch from min(x.t)) * 1000)::bigint from (
        select d.created_at as t from public.duels d where d.a_player = v_player or d.b_player = v_player
        union all
        select s.started_at from public.scores s where s.player_id = v_player
        union all
        select k.created_at from public.accounts k where k.player_id = v_player
      ) x),
    'duels', (select json_build_object(
        'played',      count(*) filter (where r.final),
        'wins',        count(*) filter (where r.result = 'win'),
        'losses',      count(*) filter (where r.result = 'loss'),
        'draws',       count(*) filter (where r.result = 'draw'),
        'open',        count(*) filter (where not r.final),
        'rounds_won',  coalesce(sum(r.my_rounds) filter (where r.final), 0),
        'rounds_lost', coalesce(sum(r.opp_rounds) filter (where r.final), 0),
        'avg_pts',     round(avg(r.my_pts) filter (where r.final)),
        'best_pts',    max(r.my_pts) filter (where r.final),
        'needles',     (select count(*) from r r2, unnest(r2.my_tiers) t where t = 4)
      ) from r),
    'history', (select coalesce(json_agg(h order by h.t desc), '[]'::json) from (
        select r.code, (extract(epoch from r.created_at) * 1000)::bigint as t, r.result,
               r.opp_name, r.opp_pid, r.my_status, r.opp_status,
               case when r.final then r.my_rounds end as my_rounds,
               case when r.final then r.opp_rounds end as opp_rounds,
               case when r.final then r.my_pts end as my_pts,
               case when r.final then r.opp_pts end as opp_pts
          from r
         where r.final or v_me
         order by r.created_at desc
         limit 30
      ) h),
    'rivals', (select coalesce(json_agg(x order by x.games desc, x.wins desc), '[]'::json) from (
        select r.opp_pid as pid, max(r.opp_name) as name, count(*) as games,
               count(*) filter (where r.result = 'win') as wins,
               count(*) filter (where r.result = 'loss') as losses
          from r
         where r.final and r.opp_pid is not null
         group by r.opp_pid
         order by count(*) desc
         limit 5
      ) x),
    'daily', (select json_build_object(
        'played', count(*),
        'avg',    round(avg(s.score)),
        'best',   max(s.score),
        'wins',   count(*) filter (where s.name is not null and s.score > 0 and s.score =
                    (select max(s2.score) from public.scores s2 where s2.day = s.day and s2.name is not null)),
        'needles', (select count(*) from public.scores s3, unnest(s3.tiers) t where s3.player_id = v_player and t = 4)
      ) from public.scores s
      where s.player_id = v_player and (s.status = 'done' or s.day < v_today))
  ) into v_json;
  return v_json;
end;
$$;

revoke all on function public.register(text, text, text) from public;
revoke all on function public.login(text, text) from public;
revoke all on function public.start_daily(date, text) from public;
revoke all on function public.set_name(uuid, uuid, text) from public;
revoke all on function public.create_duel(text, text, text[]) from public;
revoke all on function public.join_duel(text, text, text) from public;
revoke all on function public.get_profile(text, text) from public;
grant execute on function public.register(text, text, text) to anon, authenticated;
grant execute on function public.login(text, text) to anon, authenticated;
grant execute on function public.start_daily(date, text) to anon, authenticated;
grant execute on function public.set_name(uuid, uuid, text) to anon, authenticated;
grant execute on function public.create_duel(text, text, text[]) to anon, authenticated;
grant execute on function public.join_duel(text, text, text) to anon, authenticated;
grant execute on function public.get_profile(text, text) to anon, authenticated;


-- ============================================================
-- Teil 5 · Profilbilder, Level (XP), Rangliste, freies Spiel
-- ============================================================

-- Profilbild: entweder ein Symbol ("icon:name:farbe") oder ein kleines Foto (verkleinert, als Text gespeichert).
alter table public.accounts add column if not exists avatar text;
alter table public.accounts add column if not exists avatar_at timestamptz;
alter table public.accounts add column if not exists pid text
  generated always as (left(md5('heuhaufen:' || player_id), 12)) stored;
create index if not exists accounts_pid_idx on public.accounts (pid);

alter table public.accounts drop constraint if exists accounts_avatar_check;
alter table public.accounts add constraint accounts_avatar_check check (
  avatar is null or (
    char_length(avatar) <= 60000
    and (avatar ~ '^icon:[a-z0-9]{1,16}:[0-9]{1,2}$'
      or avatar ~ '^data:image/(jpeg|png|webp);base64,[A-Za-z0-9+/]+=*$')
  )
);

-- Profilbild setzen oder (mit leerem Wert) entfernen. Geht nur für das eigene Profil.
create or replace function public.set_avatar(p_player text, p_avatar text)
returns json
language plpgsql security definer set search_path = public
as $$
declare
  v_av text := nullif(p_avatar, '');
begin
  if p_player is null or char_length(p_player) not between 8 and 64 then
    raise exception 'bad_player';
  end if;
  if v_av is not null and (
       char_length(v_av) > 60000
       or not (v_av ~ '^icon:[a-z0-9]{1,16}:[0-9]{1,2}$'
            or v_av ~ '^data:image/(jpeg|png|webp);base64,[A-Za-z0-9+/]+=*$')) then
    raise exception 'bad_avatar';
  end if;
  update public.accounts k set avatar = v_av, avatar_at = now() where k.player_id = p_player;
  if not found then
    raise exception 'need_account';
  end if;
  return json_build_object('ok', true);
end;
$$;

-- Profilbilder für eine Liste öffentlicher Kennungen holen (höchstens 60 auf einmal).
create or replace function public.get_avatars(p_pids text[])
returns json
language sql security definer set search_path = public stable
as $$
  select coalesce(json_object_agg(k.pid, k.avatar), '{}'::json)
    from public.accounts k
   where k.avatar is not null and k.pid = any (p_pids[1:60]);
$$;

-- Freies Spiel: Jede Runde zählt fürs Profil und bringt die halben Punkte als XP.
-- Höchstens eine Runde alle 20 Sekunden und 60 Runden pro Tag werden gewertet.
alter table public.accounts add column if not exists free_rounds  integer not null default 0;
alter table public.accounts add column if not exists free_xp      integer not null default 0;
alter table public.accounts add column if not exists free_best    integer not null default 0;
alter table public.accounts add column if not exists free_needles integer not null default 0;
alter table public.accounts add column if not exists free_at      timestamptz;
alter table public.accounts add column if not exists free_day     date;
alter table public.accounts add column if not exists free_today   integer not null default 0;
-- Zeitpunkt der letzten Namensänderung (siehe Teil 6).
alter table public.accounts add column if not exists name_changed_at timestamptz;
-- Token und Shop (siehe Teil 7): ausgegebene Token, gekaufte Dinge, angelegter Namens-Stil, Glücksbringer links/rechts.
alter table public.accounts add column if not exists spent      integer not null default 0;
alter table public.accounts add column if not exists items      text[] not null default '{}';
alter table public.accounts add column if not exists name_style text;
alter table public.accounts add column if not exists charm_l    text;
alter table public.accounts add column if not exists charm_r    text;

create or replace function public.add_free(p_player text, p_tiers smallint[])
returns json
language plpgsql security definer set search_path = public
as $$
declare
  k        public.accounts;
  v_pts    integer[] := array[10, 30, 55, 80, 100];
  v_today  date := (now() at time zone 'Europe/Berlin')::date;
  v_score  integer := 0;
  v_need   integer := 0;
  v_count  integer;
  v_tier   smallint;
begin
  if p_player is null or char_length(p_player) not between 8 and 64 then
    raise exception 'bad_player';
  end if;
  if p_tiers is null or coalesce(array_length(p_tiers, 1), 0) <> 5 then
    raise exception 'bad_tiers';
  end if;
  foreach v_tier in array p_tiers loop
    if v_tier is null or v_tier < -1 or v_tier > 4 then
      raise exception 'bad_tiers';
    end if;
    if v_tier >= 0 then v_score := v_score + v_pts[v_tier + 1]; end if;
    if v_tier = 4 then v_need := v_need + 1; end if;
  end loop;
  select * into k from public.accounts x where x.player_id = p_player for update;
  if not found then
    raise exception 'need_account';
  end if;
  v_count := case when k.free_day is not distinct from v_today then k.free_today else 0 end;
  if (k.free_at is not null and k.free_at > now() - interval '20 seconds') or v_count >= 60 then
    return json_build_object('ok', false, 'xp', 0);
  end if;
  update public.accounts x
     set free_rounds  = x.free_rounds + 1,
         free_xp      = x.free_xp + v_score / 2,
         free_best    = greatest(x.free_best, v_score),
         free_needles = x.free_needles + v_need,
         free_at      = now(),
         free_day     = v_today,
         free_today   = v_count + 1
   where x.name_key = k.name_key;
  return json_build_object('ok', true, 'xp', v_score / 2);
end;
$$;

-- Erfahrungspunkte (XP): alle Punkte aus Tagesrätseln und Duellen, die halben Punkte aus dem freien Spiel,
-- plus 100 je Duellsieg und 150 je Tagessieg (Tagessiege zählen ab dem Folgetag).
create or replace function public.hh_xp(p_player text)
returns integer
language sql security definer set search_path = public stable
as $$
  select (
    coalesce((select sum(s.score) from public.scores s where s.player_id = p_player), 0)
    + coalesce((select k.free_xp from public.accounts k where k.player_id = p_player), 0)
    + coalesce((select sum(case when d.a_player = p_player then d.a_score else d.b_score end)
                  from public.duels d where d.a_player = p_player or d.b_player = p_player), 0)
    + 100 * (select count(*)
               from public.duels d cross join lateral public.hh_duel_outcome(d) o
              where d.a_status = 'done' and coalesce(d.b_status, '') = 'done'
                and ((d.a_player = p_player and o.winner = 'a') or (d.b_player = p_player and o.winner = 'b')))
    + 150 * (select count(*)
               from public.scores s
              where s.player_id = p_player and s.name is not null and s.score > 0
                and s.day < (now() at time zone 'Europe/Berlin')::date
                and s.score = (select max(s2.score) from public.scores s2 where s2.day = s.day and s2.name is not null))
  )::integer;
$$;

-- Rangliste: die 50 Profile mit den meisten XP, dazu der eigene Platz.
create or replace function public.get_ranking(p_player text)
returns json
language plpgsql security definer set search_path = public stable
as $$
declare
  v_json json;
begin
  with x as (
    select k.pid, k.name, public.hh_xp(k.player_id) as xp,
           (p_player is not null and k.player_id = p_player) as me,
           (select count(*)
              from public.duels d cross join lateral public.hh_duel_outcome(d) o
             where d.a_status = 'done' and coalesce(d.b_status, '') = 'done'
               and ((d.a_player = k.player_id and o.winner = 'a') or (d.b_player = k.player_id and o.winner = 'b'))) as wins
      from public.accounts k
  ), y as (
    select x.*, rank() over (order by x.xp desc) as pos from x
  )
  select json_build_object(
    'count', (select count(*) from y),
    'top', (select coalesce(json_agg(t order by t.pos, t.name), '[]'::json)
              from (select y.pid, y.name, y.xp, y.wins, y.me, y.pos from y order by y.pos, y.name limit 50) t),
    'me', (select row_to_json(t) from (select y.pid, y.name, y.xp, y.wins, y.pos from y where y.me limit 1) t)
  ) into v_json;
  return v_json;
end;
$$;

-- Profil lesen – jetzt mit Profilbild, XP und Siegesserien. Tagessiege zählen erst, wenn der Tag vorbei ist.
create or replace function public.get_profile(p_pid text, p_player text)
returns json
language plpgsql security definer set search_path = public stable
as $$
declare
  v_player text;
  v_me     boolean;
  v_today  date := (now() at time zone 'Europe/Berlin')::date;
  v_json   json;
begin
  if coalesce(p_pid, '') = '' then
    if p_player is null or char_length(p_player) not between 8 and 64 then
      return null;
    end if;
    v_player := p_player;
  else
    if p_pid !~ '^[0-9a-f]{12}$' then
      return null;
    end if;
    select x.p into v_player from (
      select k.player_id as p from public.accounts k where k.pid = p_pid
      union all
      select d.a_player from public.duels d where public.hh_pid(d.a_player) = p_pid
      union all
      select d.b_player from public.duels d where d.b_player is not null and public.hh_pid(d.b_player) = p_pid
      union all
      select s.player_id from public.scores s where public.hh_pid(s.player_id) = p_pid
    ) x limit 1;
    if v_player is null then
      return null;
    end if;
  end if;
  v_me := p_player is not null and p_player = v_player;

  with mine as (
    select d.code, d.created_at,
           d.a_player = v_player as is_a,
           (d.a_status = 'done' and coalesce(d.b_status, '') = 'done') as final,
           case when d.a_player = v_player then d.b_name else d.a_name end as opp_name,
           case when d.a_player = v_player
                then case when d.b_player is null then null else public.hh_pid(d.b_player) end
                else public.hh_pid(d.a_player) end as opp_pid,
           case when d.a_player = v_player then d.a_status else d.b_status end as my_status,
           case when d.a_player = v_player then d.b_status else d.a_status end as opp_status,
           case when d.a_player = v_player then d.a_tiers else d.b_tiers end as my_tiers,
           o.wa, o.wb, o.sa, o.sb, o.winner
      from public.duels d
      cross join lateral public.hh_duel_outcome(d) o
     where d.a_player = v_player or d.b_player = v_player
  ), r as (
    select m.*,
           case when not m.final then 'open'
                when m.winner is null then 'draw'
                when (m.winner = 'a') = m.is_a then 'win'
                else 'loss' end as result,
           case when m.is_a then m.wa else m.wb end as my_rounds,
           case when m.is_a then m.wb else m.wa end as opp_rounds,
           case when m.is_a then m.sa else m.sb end as my_pts,
           case when m.is_a then m.sb else m.sa end as opp_pts
      from mine m
  ), fin as (
    select r.result, r.created_at,
           row_number() over (order by r.created_at) - row_number() over (partition by r.result order by r.created_at) as grp,
           sum(case when r.result <> 'win' then 1 else 0 end) over (order by r.created_at desc) as breaks
      from r where r.final
  )
  select json_build_object(
    'pid', public.hh_pid(v_player),
    'me', v_me,
    'account', exists (select 1 from public.accounts k where k.player_id = v_player),
    'rename_next', case when v_me then (select (extract(epoch from k.name_changed_at + interval '7 days') * 1000)::bigint
                       from public.accounts k
                      where k.player_id = v_player and k.name_changed_at > now() - interval '7 days') end,
    'tokens', case when v_me then greatest(public.hh_tokens(v_player)
                 - coalesce((select k.spent from public.accounts k where k.player_id = v_player), 0), 0) end,
    'name_style', (select k.name_style from public.accounts k where k.player_id = v_player),
    'charm_l', (select k.charm_l from public.accounts k where k.player_id = v_player),
    'charm_r', (select k.charm_r from public.accounts k where k.player_id = v_player),
    'bonus', case when v_me then (
        select json_build_object('day', x.day, 'pos', x.pos, 'tokens', public.hh_day_bonus(x.pos))
          from (select s.day,
                       (select count(*) + 1 from public.scores s2
                         where s2.day = s.day and s2.name is not null and s2.score > s.score) as pos
                  from public.scores s
                 where s.player_id = v_player and s.name is not null and s.score > 0
                   and s.day < v_today and s.day >= v_today - 7
                 order by s.day desc limit 1) x) end,
    'avatar', (select k.avatar from public.accounts k where k.player_id = v_player),
    'xp', public.hh_xp(v_player),
    'free', (select json_build_object('rounds', k.free_rounds, 'best', k.free_best, 'needles', k.free_needles)
               from public.accounts k where k.player_id = v_player),
    'name', coalesce((select k.name from public.accounts k where k.player_id = v_player), (select x.n from (
        select d.a_name as n, d.created_at as t from public.duels d where d.a_player = v_player
        union all
        select d.b_name, d.created_at from public.duels d where d.b_player = v_player and d.b_name is not null
        union all
        select s.name, s.started_at from public.scores s where s.player_id = v_player and s.name is not null
      ) x order by x.t desc limit 1)),
    'since', (select (extract(epoch from min(x.t)) * 1000)::bigint from (
        select d.created_at as t from public.duels d where d.a_player = v_player or d.b_player = v_player
        union all
        select s.started_at from public.scores s where s.player_id = v_player
        union all
        select k.created_at from public.accounts k where k.player_id = v_player
      ) x),
    'duels', (select json_build_object(
        'played',      count(*) filter (where r.final),
        'wins',        count(*) filter (where r.result = 'win'),
        'losses',      count(*) filter (where r.result = 'loss'),
        'draws',       count(*) filter (where r.result = 'draw'),
        'open',        count(*) filter (where not r.final),
        'rounds_won',  coalesce(sum(r.my_rounds) filter (where r.final), 0),
        'rounds_lost', coalesce(sum(r.opp_rounds) filter (where r.final), 0),
        'avg_pts',     round(avg(r.my_pts) filter (where r.final)),
        'best_pts',    max(r.my_pts) filter (where r.final),
        'needles',     (select count(*) from r r2, unnest(r2.my_tiers) t where t = 4),
        'streak',      (select count(*) from fin f where f.breaks = 0),
        'best_streak', (select coalesce(max(z.c), 0) from (select count(*) as c from fin f where f.result = 'win' group by f.grp) z)
      ) from r),
    'history', (select coalesce(json_agg(h order by h.t desc), '[]'::json) from (
        select r.code, (extract(epoch from r.created_at) * 1000)::bigint as t, r.result,
               r.opp_name, r.opp_pid, r.my_status, r.opp_status,
               case when r.final then r.my_rounds end as my_rounds,
               case when r.final then r.opp_rounds end as opp_rounds,
               case when r.final then r.my_pts end as my_pts,
               case when r.final then r.opp_pts end as opp_pts
          from r
         where r.final or v_me
         order by r.created_at desc
         limit 30
      ) h),
    'rivals', (select coalesce(json_agg(x order by x.games desc, x.wins desc), '[]'::json) from (
        select r.opp_pid as pid, max(r.opp_name) as name, count(*) as games,
               count(*) filter (where r.result = 'win') as wins,
               count(*) filter (where r.result = 'loss') as losses
          from r
         where r.final and r.opp_pid is not null
         group by r.opp_pid
         order by count(*) desc
         limit 5
      ) x),
    'daily', (select json_build_object(
        'played', count(*),
        'avg',    round(avg(s.score)),
        'best',   max(s.score),
        'wins',   count(*) filter (where s.day < v_today and s.name is not null and s.score > 0 and s.score =
                    (select max(s2.score) from public.scores s2 where s2.day = s.day and s2.name is not null)),
        'needles', (select count(*) from public.scores s3, unnest(s3.tiers) t where s3.player_id = v_player and t = 4)
      ) from public.scores s
      where s.player_id = v_player and (s.status = 'done' or s.day < v_today))
  ) into v_json;
  return v_json;
end;
$$;

revoke all on function public.hh_xp(text) from public, anon, authenticated;
revoke all on function public.set_avatar(text, text) from public;
revoke all on function public.add_free(text, smallint[]) from public;
revoke all on function public.get_avatars(text[]) from public;
revoke all on function public.get_ranking(text) from public;
revoke all on function public.get_profile(text, text) from public;
grant execute on function public.set_avatar(text, text) to anon, authenticated;
grant execute on function public.add_free(text, smallint[]) to anon, authenticated;
grant execute on function public.get_avatars(text[]) to anon, authenticated;
grant execute on function public.get_ranking(text) to anon, authenticated;
grant execute on function public.get_profile(text, text) to anon, authenticated;


-- ============================================================
-- Teil 6 · Namen ändern (einmal pro Woche)
-- ============================================================

-- Name ändern: höchstens einmal in 7 Tagen. Der neue Name gilt überall – auch in alten
-- Bestenlisten und Duellen – und ist danach der Name für die Anmeldung. Das Passwort bleibt.
create or replace function public.change_name(p_player text, p_name text)
returns json
language plpgsql security definer set search_path = public
as $$
declare
  k public.accounts;
begin
  if p_player is null or char_length(p_player) not between 8 and 64 then
    raise exception 'bad_player';
  end if;
  if p_name is null or p_name !~ '^[A-Za-z0-9ÄÖÜäöüß_.-]{2,10}$' then
    raise exception 'bad_name';
  end if;
  select * into k from public.accounts x where x.player_id = p_player for update;
  if not found then
    raise exception 'need_account';
  end if;
  if k.name = p_name then
    raise exception 'same_name';
  end if;
  if k.name_changed_at is not null and k.name_changed_at > now() - interval '7 days' then
    return json_build_object('ok', false, 'error', 'too_soon',
      'next', (extract(epoch from k.name_changed_at + interval '7 days') * 1000)::bigint);
  end if;
  if lower(p_name) <> k.name_key
     and exists (select 1 from public.accounts x where x.name_key = lower(p_name)) then
    raise exception 'name_taken';
  end if;
  begin
    update public.accounts x
       set name_key = lower(p_name), name = p_name, name_changed_at = now()
     where x.player_id = p_player;
  exception when unique_violation then
    raise exception 'name_taken';
  end;
  update public.scores s set name = p_name where s.player_id = p_player and s.name is not null;
  update public.duels d set a_name = p_name where d.a_player = p_player;
  update public.duels d set b_name = p_name where d.b_player = p_player;
  return json_build_object('ok', true, 'name', p_name,
    'next', (extract(epoch from now() + interval '7 days') * 1000)::bigint);
end;
$$;

revoke all on function public.change_name(text, text) from public;
grant execute on function public.change_name(text, text) to anon, authenticated;

-- ============================================================
-- Teil 7 · Token und Shop (bunte Namen, Glücksbringer)
-- ============================================================

-- Was es im Shop gibt und was es kostet. Die Preise hier sind maßgeblich.
create table if not exists public.shop_items (
  id    text primary key check (id ~ '^[a-z0-9_]{2,24}$'),
  kind  text not null check (kind in ('name', 'charm')),
  price integer not null check (price between 1 and 100000)
);
alter table public.shop_items enable row level security;
revoke all on table public.shop_items from anon, authenticated;

insert into public.shop_items (id, kind, price) values
  ('n_rot', 'name', 100), ('n_orange', 'name', 100), ('n_gruen', 'name', 100), ('n_tuerkis', 'name', 100),
  ('n_blau', 'name', 100), ('n_lila', 'name', 100), ('n_pink', 'name', 100), ('n_gold', 'name', 250),
  ('n_sonne', 'name', 300), ('n_polar', 'name', 300), ('n_feuer', 'name', 300), ('n_ozean', 'name', 300),
  ('n_regen', 'name', 600), ('n_glanz', 'name', 900),
  ('c_klee', 'charm', 150), ('c_kaefer', 'charm', 200), ('c_pilz', 'charm', 250), ('c_blume', 'charm', 250),
  ('c_hufeisen', 'charm', 300), ('c_maus', 'charm', 350), ('c_schwein', 'charm', 400), ('c_stern', 'charm', 500),
  ('c_scheuche', 'charm', 800)
on conflict (id) do update set kind = excluded.kind, price = excluded.price;

-- Bonus am Tagesende für alle, die in der Bestenliste stehen: bewusst klein.
create or replace function public.hh_day_bonus(p_pos bigint)
returns integer
language sql immutable
as $$ select case when p_pos = 1 then 25 when p_pos = 2 then 15 when p_pos = 3 then 10 else 5 end $$;

-- Verdiente Token insgesamt: 1 Token je 10 Punkte in Tagesrätsel und Duell, 1 Token je 20 Punkte in Classic,
-- 10 je Duellsieg, dazu der Tagesbonus (erst wenn der Tag vorbei ist).
create or replace function public.hh_tokens(p_player text)
returns integer
language sql security definer set search_path = public stable
as $$
  select (
    (coalesce((select sum(s.score) from public.scores s where s.player_id = p_player), 0)
     + coalesce((select sum(case when d.a_player = p_player then d.a_score else d.b_score end)
                   from public.duels d where d.a_player = p_player or d.b_player = p_player), 0)) / 10
    + coalesce((select k.free_xp from public.accounts k where k.player_id = p_player), 0) / 10
    + 10 * (select count(*)
              from public.duels d cross join lateral public.hh_duel_outcome(d) o
             where d.a_status = 'done' and coalesce(d.b_status, '') = 'done'
               and ((d.a_player = p_player and o.winner = 'a') or (d.b_player = p_player and o.winner = 'b')))
    + coalesce((select sum(public.hh_day_bonus(
                  (select count(*) + 1 from public.scores s2
                    where s2.day = s.day and s2.name is not null and s2.score > s.score)))
                  from public.scores s
                 where s.player_id = p_player and s.name is not null and s.score > 0
                   and s.day < (now() at time zone 'Europe/Berlin')::date), 0)
  )::integer;
$$;

-- Shop-Stand lesen: Kontostand, gekaufte Dinge, was gerade angelegt ist, dazu alle Preise.
create or replace function public.get_shop(p_player text)
returns json
language plpgsql security definer set search_path = public stable
as $$
declare
  k public.accounts;
  v_found boolean := false;
begin
  if p_player is not null and char_length(p_player) between 8 and 64 then
    select * into k from public.accounts x where x.player_id = p_player;
    v_found := found;
  end if;
  return json_build_object(
    'account', v_found,
    'tokens', case when v_found then greatest(public.hh_tokens(p_player) - k.spent, 0) else 0 end,
    'items', case when v_found then to_json(k.items) else '[]'::json end,
    'name_style', case when v_found then k.name_style end,
    'charm_l', case when v_found then k.charm_l end,
    'charm_r', case when v_found then k.charm_r end,
    'prices', (select coalesce(json_object_agg(i.id, i.price), '{}'::json) from public.shop_items i)
  );
end;
$$;

-- Kaufen. Ein neuer Namens-Stil wird gleich angelegt, ein Glücksbringer auf freie Plätze gestellt.
create or replace function public.buy_item(p_player text, p_item text)
returns json
language plpgsql security definer set search_path = public
as $$
declare
  k     public.accounts;
  it    public.shop_items;
  v_bal integer;
begin
  if p_player is null or char_length(p_player) not between 8 and 64 then
    raise exception 'bad_player';
  end if;
  select * into it from public.shop_items i where i.id = p_item;
  if not found then
    raise exception 'bad_item';
  end if;
  select * into k from public.accounts x where x.player_id = p_player for update;
  if not found then
    raise exception 'need_account';
  end if;
  if p_item = any (k.items) then
    raise exception 'already_owned';
  end if;
  v_bal := public.hh_tokens(p_player) - k.spent;
  if v_bal < it.price then
    return json_build_object('ok', false, 'error', 'too_poor', 'tokens', greatest(v_bal, 0), 'price', it.price);
  end if;
  update public.accounts x
     set items = array_append(x.items, p_item),
         spent = x.spent + it.price,
         name_style = case when it.kind = 'name' then p_item else x.name_style end,
         charm_l = case when it.kind = 'charm' and x.charm_l is null then p_item else x.charm_l end,
         charm_r = case when it.kind = 'charm' and x.charm_r is null then p_item else x.charm_r end
   where x.player_id = p_player;
  return (public.get_shop(p_player)::jsonb || jsonb_build_object('ok', true))::json;
end;
$$;

-- An- und ablegen. Platz: 'name', 'left' oder 'right'. Leerer Wert legt ab.
create or replace function public.equip_item(p_player text, p_slot text, p_item text)
returns json
language plpgsql security definer set search_path = public
as $$
declare
  k      public.accounts;
  v_item text := nullif(p_item, '');
  v_kind text;
begin
  if p_player is null or char_length(p_player) not between 8 and 64 then
    raise exception 'bad_player';
  end if;
  if p_slot is null or p_slot not in ('name', 'left', 'right') then
    raise exception 'bad_slot';
  end if;
  select * into k from public.accounts x where x.player_id = p_player for update;
  if not found then
    raise exception 'need_account';
  end if;
  if v_item is not null then
    select i.kind into v_kind from public.shop_items i where i.id = v_item;
    if v_kind is null or not (v_item = any (k.items))
       or v_kind <> (case when p_slot = 'name' then 'name' else 'charm' end) then
      raise exception 'not_owned';
    end if;
  end if;
  update public.accounts x
     set name_style = case when p_slot = 'name'  then v_item else x.name_style end,
         charm_l    = case when p_slot = 'left'  then v_item else x.charm_l end,
         charm_r    = case when p_slot = 'right' then v_item else x.charm_r end
   where x.player_id = p_player;
  return (public.get_shop(p_player)::jsonb || jsonb_build_object('ok', true))::json;
end;
$$;

-- Aussehen für eine Liste öffentlicher Kennungen: Profilbild, Namens-Stil, Glücksbringer (höchstens 60 auf einmal).
create or replace function public.get_looks(p_pids text[])
returns json
language sql security definer set search_path = public stable
as $$
  select coalesce(json_object_agg(k.pid, json_build_object('a', k.avatar, 'n', k.name_style, 'l', k.charm_l, 'r', k.charm_r)), '{}'::json)
    from public.accounts k
   where k.pid = any (p_pids[1:60])
     and (k.avatar is not null or k.name_style is not null or k.charm_l is not null or k.charm_r is not null);
$$;

revoke all on function public.hh_day_bonus(bigint) from public, anon, authenticated;
revoke all on function public.hh_tokens(text) from public, anon, authenticated;
revoke all on function public.get_shop(text) from public;
revoke all on function public.buy_item(text, text) from public;
revoke all on function public.equip_item(text, text, text) from public;
revoke all on function public.get_looks(text[]) from public;
grant execute on function public.get_shop(text) to anon, authenticated;
grant execute on function public.buy_item(text, text) to anon, authenticated;
grant execute on function public.equip_item(text, text, text) to anon, authenticated;
grant execute on function public.get_looks(text[]) to anon, authenticated;

-- ============================================================
-- Teil 8 · Live-Duell in Lobbys (2 bis 9 Spieler, privat oder öffentlich)
-- ============================================================
-- Ablauf: Jemand öffnet eine Lobby (lobby_create) – privat (nur mit dem 4-stelligen Code oder Link)
-- oder öffentlich (steht in der Liste, lobby_list) – und legt fest, gegen wie viele Leute gespielt
-- wird (1 bis 8 Gegner) und wie viele Fragen es gibt (3 bis 10). Bis zum Start kann der Gastgeber
-- das in der Lobby ändern (lobby_settings), Spieler entfernen (lobby_kick) und startet das Spiel
-- (lobby_start). Danach läuft jede Frage für alle zur selben Zeit; die Uhr führt die Datenbank.
-- Was die anderen geantwortet haben, gibt sie erst zur Auflösung heraus. Alle Übergänge (Auflösung,
-- nächste Frage, Ende) werden beim Abfragen aus den Zeitstempeln berechnet; es läuft kein Dienst im
-- Hintergrund.
-- Wertung: Antworten, die mehrere Spieler gleich gegeben haben, zählen für keinen von ihnen. Die Runde
-- holt, wer als Einziger am tiefsten landet. Es gewinnt, wer die meisten Runden holt; bei Gleichstand
-- zählen die Punkte. Ein Spiel zu zweit wird am Ende als Duell gespeichert (Statistik, Historie),
-- ein Spiel mit mehr Leuten als Mehrspieler-Runde.

-- Spalten für das Duell-Ergebnis (live = live gespielt). Die übrigen stammen aus der ersten Fassung
-- des Live-Duells und werden nur noch zum Aufräumen gebraucht.
alter table public.duels add column if not exists live        boolean not null default false;
alter table public.duels add column if not exists room        text;
alter table public.duels add column if not exists live_i      smallint not null default 0;
alter table public.duels add column if not exists live_q_at   timestamptz;
alter table public.duels add column if not exists live_rev_at timestamptz;
alter table public.duels add column if not exists a_seen      timestamptz;
alter table public.duels add column if not exists b_seen      timestamptz;
alter table public.duels add column if not exists rematch     text;
drop index if exists public.duels_room_idx;

-- Aufräumen nach der ersten Fassung (Live-Duell nur zu zweit, direkt in der Tabelle duels):
-- nie gestartete Räume löschen, liegengebliebene Duelle zu Ende zählen, alte Funktionen entfernen.
delete from public.duels d where d.live and d.live_q_at is null and d.a_status <> 'done';
update public.duels d
   set a_tiers   = d.a_tiers   || array(select (-1)::smallint from generate_series(1, 5 - cardinality(d.a_tiers))),
       a_answers = d.a_answers || array(select ''::text from generate_series(1, 5 - cardinality(d.a_answers))),
       b_tiers   = d.b_tiers   || array(select (-1)::smallint from generate_series(1, 5 - cardinality(d.b_tiers))),
       b_answers = d.b_answers || array(select ''::text from generate_series(1, 5 - cardinality(d.b_answers))),
       a_status = 'done', b_status = 'done',
       a_done_at = coalesce(d.a_done_at, now()), b_done_at = coalesce(d.b_done_at, now())
 where d.live and d.live_q_at is not null and d.b_player is not null
   and (d.a_status <> 'done' or coalesce(d.b_status, '') <> 'done')
   and d.live_q_at < now() - interval '10 minutes';
drop function if exists public.live_create(text, text[]);
drop function if exists public.live_join(text, text);
drop function if exists public.live_leave(text, text);
drop function if exists public.live_poll(text, text);
drop function if exists public.live_poll(text, text, boolean);
drop function if exists public.live_answer(text, text, integer, smallint, text);
drop function if exists public.live_rematch(text, text, text[]);
drop function if exists public.hh_live_sweep();
drop function if exists public.hh_live_tick(text, text);
drop function if exists public.hh_live_tick(text, text, boolean);
drop function if exists public.hh_live_json(public.duels, text);
drop function if exists public.hh_live_ms(text);
drop function if exists public.lobby_create(text, text[], boolean, integer);   -- ältere Fassung ohne Fragenzahl

-- Eine Lobby und danach das Spiel darin.
create table if not exists public.lobbies (
  code        text primary key check (code ~ '^[A-Z2-9]{5}$'),
  room        text not null check (room ~ '^[0-9]{4}$'),      -- 4-stelliger Code zum Beitreten
  created_at  timestamptz not null default now(),
  host        text not null,
  is_public   boolean not null default false,
  cap         smallint not null check (cap between 2 and 9),  -- Plätze insgesamt (Gastgeber + Gegner)
  qids        text[] not null,                                -- ausgeloste Fragen (bis zu 10)
  nq          smallint not null default 5,                    -- davon gespielt: die ersten nq
  kicked      text[] not null default '{}',
  q_i         smallint not null default 0,                    -- aktuelle Frage (0 bis 4)
  q_at        timestamptz,                                    -- Start der aktuellen Frage (leer: Lobby noch offen)
  rev_at      timestamptz,                                    -- Start der Auflösung (leer: noch offen)
  done        boolean not null default false,
  done_at     timestamptz,
  n           smallint,                                       -- Zahl der Spieler am Ende
  next_code   text                                            -- Lobby der nächsten Runde ("Nochmal")
);
-- Der Raum-Code muss nur unter den offenen Lobbys eindeutig sein; nach dem Start ist er wieder frei.
create unique index if not exists lobbies_room_idx on public.lobbies (room) where q_at is null;
-- Fragenzahl (3 bis 10). Ältere Fassungen hatten genau 5 Fragen – für vorhandene Tabellen nachrüsten.
alter table public.lobbies add column if not exists nq smallint not null default 5;
alter table public.lobbies drop constraint if exists lobbies_qids_check;
alter table public.lobbies add constraint lobbies_qids_check check (array_length(qids, 1) between 3 and 10);
alter table public.lobbies drop constraint if exists lobbies_nq_check;
alter table public.lobbies add constraint lobbies_nq_check check (nq between 3 and 10 and nq <= array_length(qids, 1));
-- Ein Spiel zu zweit wird als Duell gespeichert – auch mit mehr oder weniger als 5 Fragen.
alter table public.duels drop constraint if exists duels_qids_check;
alter table public.duels add constraint duels_qids_check check (array_length(qids, 1) between 3 and 10);
create index if not exists lobbies_host_idx on public.lobbies (host, created_at);

create table if not exists public.lobby_players (
  code       text not null references public.lobbies (code) on delete cascade,
  player     text not null,
  pos        integer not null default 0,                      -- Reihenfolge des Beitritts
  joined_at  timestamptz not null default now(),
  seen       timestamptz,
  tiers      smallint[] not null default '{}',
  answers    text[] not null default '{}',
  score      integer not null default 0,
  rounds     integer,                                         -- ab hier: Ergebnis, am Ende eingetragen
  pts        integer,
  place      integer,
  won        boolean,
  primary key (code, player)
);
create index if not exists lobby_players_player_idx on public.lobby_players (player);

alter table public.lobbies enable row level security;
alter table public.lobby_players enable row level security;
revoke all on table public.lobbies from anon, authenticated;
revoke all on table public.lobby_players from anon, authenticated;

-- Zeiten in Millisekunden: Countdown, Antwortzeit, Nachlauf fürs Netz, Vorlauf zur Auflösung, Dauer der Auflösung.
create or replace function public.hh_lobby_ms(p_what text)
returns integer
language sql immutable
as $$
  select case p_what when 'count' then 5000 when 'ask' then 30000 when 'grace' then 1500
                     when 'lead' then 1200 when 'reveal' then 10000 end
$$;

-- Wertung eines Spiels: Runden, Punkte, Platz.
create or replace function public.hh_lobby_rank(p_code text)
returns table (player text, rounds integer, pts integer, place integer, won boolean)
language sql stable security definer set search_path = public
as $$
  with a as (       -- eine Zeile je Spieler und Frage
    select p.player, i, coalesce(p.tiers[i], -1) as t, lower(coalesce(p.answers[i], '')) as ans
      from public.lobby_players p
      cross join generate_series(1, (select l.nq from public.lobbies l where l.code = p_code)) i
     where p.code = p_code
  ), v as (         -- gleiche Antworten zählen für keinen
    select a.*,
           case when a.t >= 0 and a.ans <> ''
                 and count(*) filter (where a.t >= 0 and a.ans <> '') over (partition by a.i, a.ans) > 1
                then -1 else a.t end as vt
      from a
  ), r as (         -- je Frage: die tiefste gültige Stufe – und wie viele dort gelandet sind
    select v.*, max(v.vt) over (partition by v.i) as top,
           count(*) over (partition by v.i, v.vt) as same_depth
      from v
  ), s as (
    select r.player,
           sum(case when r.vt >= 0 and r.vt = r.top and r.same_depth = 1 then 1 else 0 end)::integer as rounds,
           sum(case when r.vt >= 0 then (array[10, 30, 55, 80, 100])[r.vt + 1] else 0 end)::integer as pts
      from r group by r.player
  ), z as (
    select s.*, rank() over (order by s.rounds desc, s.pts desc)::integer as place from s
  )
  select z.player, z.rounds, z.pts, z.place,
         (z.place = 1 and (select count(*) from z z2 where z2.place = 1) = 1) as won
    from z;
$$;

-- Spielende: Ergebnis eintragen. Zu zweit wird daraus ein Duell (mit Statistik und Historie wie bisher),
-- bei mehr Spielern gibt es die XP direkt aufs Konto (Punkte, dazu 100 für den Sieg – wie beim Duell).
create or replace function public.hh_lobby_finish(p_code text)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  l      public.lobbies;
  a      public.lobby_players;
  b      public.lobby_players;
  v_n    integer;
  v_an   text;
  v_bn   text;
begin
  select * into l from public.lobbies x where x.code = p_code;
  select count(*) into v_n from public.lobby_players p where p.code = p_code;
  update public.lobbies x set n = v_n where x.code = p_code;
  update public.lobby_players p
     set rounds = r.rounds, pts = r.pts, place = r.place, won = r.won
    from public.hh_lobby_rank(p_code) r
   where p.code = p_code and p.player = r.player;
  if v_n = 2 then
    select * into a from public.lobby_players p where p.code = p_code order by p.pos, p.joined_at, p.player limit 1;
    select * into b from public.lobby_players p where p.code = p_code and p.player <> a.player limit 1;
    select k.name into v_an from public.accounts k where k.player_id = a.player;
    select k.name into v_bn from public.accounts k where k.player_id = b.player;
    if v_an is not null and v_bn is not null then
      insert into public.duels (code, created_at, qids, live,
                                a_player, a_name, a_tiers, a_answers, a_score, a_status, a_done_at,
                                b_player, b_secret, b_name, b_tiers, b_answers, b_score, b_status, b_done_at)
      values (l.code, l.created_at, l.qids[1:l.nq], true,
              a.player, v_an, a.tiers, a.answers, a.score, 'done', coalesce(l.done_at, now()),
              b.player, gen_random_uuid(), v_bn, b.tiers, b.answers, b.score, 'done', coalesce(l.done_at, now()))
      on conflict (code) do nothing;
      return;
    end if;
  end if;
  update public.accounts k
     set free_xp = k.free_xp + p.score + case when p.won then 100 else 0 end
    from public.lobby_players p
   where p.code = p_code and k.player_id = p.player;
end;
$$;

-- Die Uhr: sperrt die Lobby, merkt sich die Anwesenheit des Abfragenden und stellt den Stand auf die
-- aktuelle Zeit vor (Auflösung, nächste Frage, Ende). p_here ist falsch, solange die Seite vor dem
-- Start nur im Hintergrund offen ist.
create or replace function public.hh_lobby_tick(p_code text, p_player text, p_here boolean)
returns public.lobbies
language plpgsql security definer set search_path = public
as $$
declare
  l        public.lobbies;
  v_ask    interval := make_interval(secs => (public.hh_lobby_ms('ask') + public.hh_lobby_ms('grace')) / 1000.0);
  v_reveal interval := make_interval(secs => public.hh_lobby_ms('reveal') / 1000.0);
  v_lead   interval := make_interval(secs => public.hh_lobby_ms('lead') / 1000.0);
  v_touch  boolean := false;
begin
  select * into l from public.lobbies x where x.code = upper(p_code) for update;
  if not found then
    return l;
  end if;
  if p_player is not null and coalesce(p_here, true) then
    update public.lobby_players p set seen = now()
     where p.code = l.code and p.player = p_player
       and (l.q_at is null or p.seen is null or p.seen < now() - interval '2.5 seconds');
  end if;
  if l.q_at is null then
    -- Offene Lobby: Wer die Seite länger nicht offen hatte, macht seinen Platz frei (der Gastgeber bleibt).
    delete from public.lobby_players p
     where p.code = l.code and p.player <> l.host and coalesce(p.seen, p.joined_at) < now() - interval '30 seconds';
    return l;
  end if;
  loop
    exit when l.done or now() < l.q_at;
    if l.rev_at is null then
      if now() >= l.q_at + v_ask then
        l.rev_at := l.q_at + v_ask; v_touch := true;                       -- Zeit um
      elsif (select count(*) > 0 and count(*) filter (where cardinality(p.tiers) <= l.q_i) = 0
               from public.lobby_players p
              where p.code = l.code and p.seen > now() - interval '8 seconds') then
        l.rev_at := now() + v_lead; v_touch := true;                       -- alle, die da sind, haben geantwortet
      else
        exit;
      end if;
    end if;
    exit when now() < l.rev_at;
    -- Die Auflösung läuft: Wer nicht geantwortet hat, bekommt "keine Antwort".
    update public.lobby_players p
       set tiers   = p.tiers   || array(select (-1)::smallint from generate_series(1, l.q_i + 1 - cardinality(p.tiers))),
           answers = p.answers || array(select ''::text from generate_series(1, l.q_i + 1 - cardinality(p.answers)))
     where p.code = l.code and (cardinality(p.tiers) < l.q_i + 1 or cardinality(p.answers) < l.q_i + 1);
    if l.q_i >= l.nq - 1 then
      l.done := true; l.done_at := l.rev_at; v_touch := true;
      update public.lobbies x set done = true, done_at = l.done_at, rev_at = l.rev_at where x.code = l.code;
      perform public.hh_lobby_finish(l.code);
      exit;
    end if;
    exit when now() < l.rev_at + v_reveal;
    l.q_i := l.q_i + 1; l.q_at := l.rev_at + v_reveal; l.rev_at := null; v_touch := true;
  end loop;
  if v_touch then
    update public.lobbies x
       set q_i = l.q_i, q_at = l.q_at, rev_at = l.rev_at, done = l.done, done_at = l.done_at
     where x.code = l.code;
  end if;
  return l;
end;
$$;

-- Der Stand, wie ihn ein Spieler sehen darf: die eigenen Antworten immer, die der anderen erst ab der
-- Auflösung der jeweiligen Frage.
create or replace function public.hh_lobby_json(l public.lobbies, p_player text)
returns json
language plpgsql stable security definer set search_path = public
as $$
declare
  v_reveal interval := make_interval(secs => public.hh_lobby_ms('reveal') / 1000.0);
  v_away   interval := case when l.q_at is null then interval '5 seconds' else interval '8 seconds' end;
  v_phase  text;
  v_open   integer;
begin
  v_phase := case
    when l.q_at is null then 'open'
    when now() < l.q_at then 'count'
    when l.done and now() >= l.rev_at + v_reveal then 'done'
    when l.rev_at is not null and now() >= l.rev_at then 'reveal'
    else 'ask' end;
  v_open := case when v_phase in ('open', 'count') then 0
                 when v_phase = 'ask' then l.q_i
                 when v_phase = 'done' then l.nq
                 else l.q_i + 1 end;
  return json_build_object(
    'code', l.code, 'room', l.room, 'public', l.is_public, 'cap', l.cap,
    'nq', l.nq, 'nq_max', cardinality(l.qids),
    'phase', v_phase, 'i', l.q_i, 'open', v_open, 'final', l.done,
    'in', exists (select 1 from public.lobby_players p where p.code = l.code and p.player = p_player),
    'host', l.host = p_player,
    'kicked', coalesce(p_player = any(l.kicked), false),
    'now',    (extract(epoch from now()) * 1000)::bigint,
    'q_at',   (extract(epoch from l.q_at) * 1000)::bigint,
    'rev_at', (extract(epoch from l.rev_at) * 1000)::bigint,
    'count_ms', public.hh_lobby_ms('count'), 'ask_ms', public.hh_lobby_ms('ask'),
    'grace_ms', public.hh_lobby_ms('grace'), 'reveal_ms', public.hh_lobby_ms('reveal'),
    'qids', l.qids[1:l.nq],
    'players', (select coalesce(json_agg(json_build_object(
          'pid', public.hh_pid(p.player), 'name', coalesce(k.name, '???'),
          'host', p.player = l.host, 'me', p.player = p_player,
          'here', coalesce(p.seen > now() - v_away, false),
          'answered', cardinality(p.tiers) > l.q_i,
          'tiers',   to_json(case when p.player = p_player then p.tiers   else p.tiers[1:v_open] end),
          'answers', to_json(case when p.player = p_player then p.answers else p.answers[1:v_open] end)
        ) order by p.pos, p.joined_at, p.player), '[]'::json)
        from public.lobby_players p left join public.accounts k on k.player_id = p.player
       where p.code = l.code),
    'next', (select json_build_object('code', n.code, 'room', n.room, 'by_pid', public.hh_pid(n.host),
                                      'by', (select k.name from public.accounts k where k.player_id = n.host))
               from public.lobbies n where n.code = l.next_code and n.q_at is null)
  );
end;
$$;

-- Einen Spieler aus einer offenen Lobby nehmen. Geht der Gastgeber, übernimmt der Nächste; ist niemand
-- mehr da, wird die Lobby gelöscht.
create or replace function public.hh_lobby_drop(p_code text, p_player text)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  l      public.lobbies;
  v_next text;
begin
  select * into l from public.lobbies x where x.code = p_code and x.q_at is null for update;
  if not found then
    return;
  end if;
  delete from public.lobby_players p where p.code = l.code and p.player = p_player;
  if l.host = p_player then
    select p.player into v_next from public.lobby_players p
     where p.code = l.code order by p.pos, p.joined_at, p.player limit 1;
    if v_next is null then
      delete from public.lobbies x where x.code = l.code;
    else
      update public.lobbies x set host = v_next where x.code = l.code;
    end if;
  end if;
end;
$$;

-- Aufräumen: verlassene Lobbys löschen, liegengebliebene Spiele zu Ende zählen.
create or replace function public.hh_lobby_sweep()
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_code text;
begin
  delete from public.lobbies l
   where l.q_at is null
     and coalesce((select p.seen from public.lobby_players p where p.code = l.code and p.player = l.host), l.created_at)
         < now() - interval '30 minutes';
  for v_code in
    select l.code from public.lobbies l
     where l.q_at is not null and not l.done and l.q_at < now() - interval '50 seconds'
     order by l.code
  loop
    perform public.hh_lobby_tick(v_code, null, false);
  end loop;
end;
$$;

-- Lobby öffnen: privat oder öffentlich, mit p_cap Plätzen insgesamt (2 bis 9) und p_nq Fragen (3 bis 10).
-- Die Fragen lost die Seite aus (bis zu 10, damit der Gastgeber später noch mehr wählen kann);
-- zurück kommen der Spiel-Code und der 4-stellige Raum-Code.
create or replace function public.lobby_create(p_player text, p_qids text[], p_public boolean, p_cap integer, p_nq integer default 5)
returns json
language plpgsql security definer set search_path = public
as $$
declare
  v_alpha text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_code  text;
  v_room  text;
  v_try   integer := 0;
  v_q     text;
  v_old   text;
begin
  if p_player is null or char_length(p_player) not between 8 and 64 then
    raise exception 'bad_player';
  end if;
  if not exists (select 1 from public.accounts k where k.player_id = p_player) then
    raise exception 'need_account';
  end if;
  if p_qids is null or coalesce(array_length(p_qids, 1), 0) not between 3 and 10
     or (select count(distinct q) from unnest(p_qids) q) <> array_length(p_qids, 1) then
    raise exception 'bad_questions';
  end if;
  foreach v_q in array p_qids loop
    if v_q is null or v_q !~ '^[a-z0-9]{1,12}$' then
      raise exception 'bad_questions';
    end if;
  end loop;
  if p_cap is null or p_cap < 2 or p_cap > 9 then
    raise exception 'bad_cap';
  end if;
  if p_nq is null or p_nq < 3 or p_nq > array_length(p_qids, 1) then
    raise exception 'bad_nq';
  end if;
  perform public.hh_lobby_sweep();
  -- Man kann nur in einer offenen Lobby zugleich sein.
  for v_old in select p.code from public.lobby_players p join public.lobbies x on x.code = p.code
                where p.player = p_player and x.q_at is null order by p.code loop
    perform public.hh_lobby_drop(v_old, p_player);
  end loop;
  if (select count(*) from public.lobbies x where x.host = p_player and x.created_at > now() - interval '1 day') >= 100 then
    raise exception 'too_many';
  end if;
  loop
    v_code := '';
    for i in 1..5 loop
      v_code := v_code || substr(v_alpha, 1 + floor(random() * length(v_alpha))::int, 1);
    end loop;
    v_room := (1000 + floor(random() * 9000)::int)::text;
    if not exists (select 1 from public.duels d where d.code = v_code) then
      begin
        insert into public.lobbies (code, room, host, is_public, cap, qids, nq)
        values (v_code, v_room, p_player, coalesce(p_public, false), p_cap, p_qids, p_nq);
        insert into public.lobby_players (code, player, pos, seen) values (v_code, p_player, 0, now());
        return json_build_object('code', v_code, 'room', v_room);
      exception when unique_violation then
        null;
      end;
    end if;
    v_try := v_try + 1;
    if v_try > 40 then
      raise exception 'no_code';
    end if;
  end loop;
end;
$$;

-- Lobby betreten (mit dem 4-stelligen Code). Zurück kommt der Spiel-Code.
create or replace function public.lobby_join(p_player text, p_room text)
returns json
language plpgsql security definer set search_path = public
as $$
declare
  l     public.lobbies;
  v_old text;
begin
  if p_player is null or char_length(p_player) not between 8 and 64 then
    raise exception 'bad_player';
  end if;
  if not exists (select 1 from public.accounts k where k.player_id = p_player) then
    raise exception 'need_account';
  end if;
  if p_room is null or p_room !~ '^[0-9]{4}$' then
    raise exception 'not_found';
  end if;
  perform public.hh_lobby_sweep();
  select * into l from public.lobbies x where x.room = p_room and x.q_at is null for update;
  if not found then
    -- Läuft das Spiel mit diesem Code schon und ich bin dabei? Dann einfach wieder hinein.
    select x.* into l from public.lobbies x join public.lobby_players p on p.code = x.code
     where x.room = p_room and not x.done and p.player = p_player
     order by x.created_at desc limit 1;
    if found then
      return json_build_object('code', l.code);
    end if;
    raise exception 'not_found';
  end if;
  if p_player = any(l.kicked) then
    raise exception 'kicked';
  end if;
  if exists (select 1 from public.lobby_players p where p.code = l.code and p.player = p_player) then
    update public.lobby_players p set seen = now() where p.code = l.code and p.player = p_player;
    return json_build_object('code', l.code);
  end if;
  delete from public.lobby_players p
   where p.code = l.code and p.player <> l.host and coalesce(p.seen, p.joined_at) < now() - interval '30 seconds';
  if (select count(*) from public.lobby_players p where p.code = l.code) >= l.cap then
    raise exception 'full';
  end if;
  for v_old in select p.code from public.lobby_players p join public.lobbies x on x.code = p.code
                where p.player = p_player and x.q_at is null and p.code <> l.code order by p.code loop
    perform public.hh_lobby_drop(v_old, p_player);
  end loop;
  insert into public.lobby_players (code, player, pos, seen)
  values (l.code, p_player, coalesce((select max(p.pos) from public.lobby_players p where p.code = l.code), 0) + 1, now());
  return json_build_object('code', l.code);
end;
$$;

-- Lobby vor dem Start verlassen.
create or replace function public.lobby_leave(p_code text, p_player text)
returns boolean
language plpgsql security definer set search_path = public
as $$
begin
  if not exists (select 1 from public.lobby_players p join public.lobbies x on x.code = p.code
                  where p.code = upper(p_code) and p.player = p_player and x.q_at is null) then
    return false;
  end if;
  perform public.hh_lobby_drop(upper(p_code), p_player);
  return true;
end;
$$;

-- Der Gastgeber entfernt einen Spieler aus der offenen Lobby; der kommt in diese Lobby nicht wieder hinein.
create or replace function public.lobby_kick(p_code text, p_player text, p_pid text)
returns boolean
language plpgsql security definer set search_path = public
as $$
declare
  l        public.lobbies;
  v_target text;
begin
  select * into l from public.lobbies x where x.code = upper(p_code) for update;
  if not found then
    raise exception 'not_found';
  end if;
  if l.host is distinct from p_player then
    raise exception 'not_host';
  end if;
  if l.q_at is not null then
    raise exception 'already_started';
  end if;
  select p.player into v_target from public.lobby_players p
   where p.code = l.code and p.player <> l.host and public.hh_pid(p.player) = p_pid;
  if v_target is null then
    return false;
  end if;
  delete from public.lobby_players p where p.code = l.code and p.player = v_target;
  update public.lobbies x set kicked = array_append(x.kicked, v_target) where x.code = l.code;
  return true;
end;
$$;

-- Der Gastgeber ändert die Lobby vor dem Start: Plätze (2 bis 9, nicht weniger als schon da sind),
-- Fragen (3 bis 10) und ob sie öffentlich ist. Leere Werte bleiben, wie sie sind.
create or replace function public.lobby_settings(p_code text, p_player text, p_cap integer, p_public boolean, p_nq integer)
returns json
language plpgsql security definer set search_path = public
as $$
declare
  l   public.lobbies;
  v_n integer;
begin
  l := public.hh_lobby_tick(p_code, p_player, true);
  if l.code is null then
    raise exception 'not_found';
  end if;
  if l.host is distinct from p_player then
    raise exception 'not_host';
  end if;
  if l.q_at is not null then
    raise exception 'already_started';
  end if;
  select count(*) into v_n from public.lobby_players p where p.code = l.code;
  if p_cap is not null then
    if p_cap < 2 or p_cap > 9 then
      raise exception 'bad_cap';
    end if;
    if p_cap < v_n then
      raise exception 'cap_too_small';
    end if;
    l.cap := p_cap;
  end if;
  if p_nq is not null then
    if p_nq < 3 or p_nq > cardinality(l.qids) then
      raise exception 'bad_nq';
    end if;
    l.nq := p_nq;
  end if;
  if p_public is not null then
    l.is_public := p_public;
  end if;
  update public.lobbies x set cap = l.cap, nq = l.nq, is_public = l.is_public where x.code = l.code;
  return public.hh_lobby_json(l, p_player);
end;
$$;

-- Der Gastgeber startet das Spiel. Mit dabei ist, wer die Seite gerade offen hat – mindestens zwei.
create or replace function public.lobby_start(p_code text, p_player text)
returns json
language plpgsql security definer set search_path = public
as $$
declare
  l public.lobbies;
begin
  l := public.hh_lobby_tick(p_code, p_player, true);
  if l.code is null then
    raise exception 'not_found';
  end if;
  if l.host is distinct from p_player then
    raise exception 'not_host';
  end if;
  if l.q_at is not null then
    return public.hh_lobby_json(l, p_player);
  end if;
  delete from public.lobby_players p
   where p.code = l.code and p.player <> l.host and coalesce(p.seen, p.joined_at) < now() - interval '8 seconds';
  if (select count(*) from public.lobby_players p where p.code = l.code) < 2 then
    raise exception 'need_players';
  end if;
  update public.lobby_players p set tiers = '{}', answers = '{}', score = 0 where p.code = l.code;
  l.q_i := 0; l.q_at := now() + make_interval(secs => public.hh_lobby_ms('count') / 1000.0); l.rev_at := null;
  update public.lobbies x set q_i = l.q_i, q_at = l.q_at, rev_at = null where x.code = l.code;
  return public.hh_lobby_json(l, p_player);
end;
$$;

-- Stand abfragen (etwa einmal pro Sekunde). Gibt null zurück, wenn es die Lobby nicht (mehr) gibt.
create or replace function public.lobby_poll(p_code text, p_player text, p_here boolean default true)
returns json
language plpgsql security definer set search_path = public
as $$
declare
  l public.lobbies;
begin
  l := public.hh_lobby_tick(p_code, p_player, p_here);
  if l.code is null then
    return null;
  end if;
  return public.hh_lobby_json(l, p_player);
end;
$$;

-- Antwort einloggen (p_tier -1 = passen). Geht nur einmal je Frage und nur, solange die Uhr läuft.
-- Haben alle geantwortet, die gerade da sind, beginnt kurz darauf die Auflösung.
create or replace function public.lobby_answer(p_code text, p_player text, p_i integer, p_tier smallint, p_answer text)
returns json
language plpgsql security definer set search_path = public
as $$
declare
  l     public.lobbies;
  me    public.lobby_players;
  v_pts integer[] := array[10, 30, 55, 80, 100];
  v_ans text;
begin
  if p_tier is null or p_tier < -1 or p_tier > 4 then
    raise exception 'bad_tiers';
  end if;
  v_ans := case when p_tier >= 0 then btrim(coalesce(p_answer, '')) else '' end;
  if char_length(v_ans) > 60 or (p_tier >= 0 and v_ans = '') then
    raise exception 'bad_answers';
  end if;
  l := public.hh_lobby_tick(p_code, p_player, true);
  if l.code is null then
    raise exception 'not_found';
  end if;
  select * into me from public.lobby_players p where p.code = l.code and p.player = p_player;
  if not found then
    raise exception 'not_allowed';
  end if;
  if l.q_at is null or now() < l.q_at then
    raise exception 'too_early';
  end if;
  if l.done or p_i is distinct from l.q_i::integer or (l.rev_at is not null and now() >= l.rev_at) then
    raise exception 'too_late';
  end if;
  if cardinality(me.tiers) > l.q_i then
    raise exception 'already';
  end if;
  update public.lobby_players p
     set tiers = p.tiers || p_tier, answers = p.answers || v_ans,
         score = p.score + case when p_tier >= 0 then v_pts[p_tier + 1] else 0 end
   where p.code = l.code and p.player = p_player;
  if l.rev_at is null
     and (select count(*) > 0 and count(*) filter (where cardinality(p.tiers) <= l.q_i) = 0
            from public.lobby_players p
           where p.code = l.code and p.seen > now() - interval '8 seconds') then
    l.rev_at := now() + make_interval(secs => public.hh_lobby_ms('lead') / 1000.0);
    update public.lobbies x set rev_at = l.rev_at where x.code = l.code;
  end if;
  return public.hh_lobby_json(l, p_player);
end;
$$;

-- Nochmal: Nach einem beendeten Spiel öffnet der Erste eine neue (private) Lobby, die anderen landen in derselben.
create or replace function public.lobby_again(p_code text, p_player text, p_qids text[])
returns json
language plpgsql security definer set search_path = public
as $$
declare
  l public.lobbies;
  n public.lobbies;
  r json;
begin
  select * into l from public.lobbies x where x.code = upper(p_code) for update;
  if not found then
    raise exception 'not_found';
  end if;
  if not exists (select 1 from public.lobby_players p where p.code = l.code and p.player = p_player) then
    raise exception 'not_allowed';
  end if;
  if not l.done then
    raise exception 'not_done';
  end if;
  if l.next_code is not null then
    select * into n from public.lobbies x where x.code = l.next_code and x.q_at is null;
    if found then
      return public.lobby_join(p_player, n.room);
    end if;
  end if;
  r := public.lobby_create(p_player, p_qids, false, greatest(l.cap, coalesce(l.n, 2))::integer,
                           least(l.nq::integer, coalesce(array_length(p_qids, 1), 0)));
  update public.lobbies x set next_code = r ->> 'code' where x.code = l.code;
  return r;
end;
$$;

-- Öffentliche Lobbys, in denen noch Platz ist und deren Gastgeber gerade da ist.
create or replace function public.lobby_list(p_player text)
returns json
language sql stable security definer set search_path = public
as $$
  select coalesce(json_agg(json_build_object('room', x.room, 'host', x.name, 'host_pid', x.pid, 'n', x.n, 'cap', x.cap)
                           order by x.created_at desc), '[]'::json)
    from (
      select l.room, l.cap, l.created_at, k.name, public.hh_pid(l.host) as pid,
             (select count(*) from public.lobby_players p where p.code = l.code) as n
        from public.lobbies l join public.accounts k on k.player_id = l.host
       where l.is_public and l.q_at is null
         and l.host is distinct from p_player
         and not coalesce(p_player = any(l.kicked), false)
         and exists (select 1 from public.lobby_players p
                      where p.code = l.code and p.player = l.host and p.seen > now() - interval '12 seconds')
         and (select count(*) from public.lobby_players p where p.code = l.code) < l.cap
       order by l.created_at desc limit 30
    ) x;
$$;

-- Mehrspieler-Runden (ab 3 Spielern) fürs Profil: Zahlen und die letzten Spiele.
create or replace function public.lobby_stats(p_pid text, p_player text)
returns json
language plpgsql stable security definer set search_path = public
as $$
declare
  v_player text;
begin
  if p_pid is not null then
    select k.player_id into v_player from public.accounts k where k.pid = p_pid;
  else
    v_player := p_player;
  end if;
  if v_player is null then
    return json_build_object('played', 0, 'wins', 0, 'top3', 0, 'recent', '[]'::json);
  end if;
  return (
    with m as (
      select l.code, l.done_at, l.n, p.place, p.pts, p.rounds, p.won
        from public.lobby_players p join public.lobbies l on l.code = p.code
       where p.player = v_player and l.done and l.n >= 3
    )
    select json_build_object(
      'played', (select count(*) from m),
      'wins',   (select count(*) from m where m.won),
      'top3',   (select count(*) from m where m.place <= 3),
      'recent', (select coalesce(json_agg(json_build_object('code', x.code, 't', (extract(epoch from x.done_at) * 1000)::bigint,
                                                           'n', x.n, 'place', x.place, 'pts', x.pts, 'rounds', x.rounds, 'won', x.won)
                                          order by x.done_at desc), '[]'::json)
                   from (select * from m order by m.done_at desc limit 8) x))
  );
end;
$$;

-- Die Funktionen des alten Duells per Link dürfen Live-Duelle nicht anfassen.
create or replace function public.join_duel(p_code text, p_player text, p_name text)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  d        public.duels;
  v_name   text;
  v_secret uuid := gen_random_uuid();
begin
  if p_player is null or char_length(p_player) not between 8 and 64 then
    raise exception 'bad_player';
  end if;
  select k.name into v_name from public.accounts k where k.player_id = p_player;
  if v_name is null then
    raise exception 'need_account';
  end if;
  select * into d from public.duels x where x.code = upper(p_code) for update;
  if not found or d.live then
    raise exception 'not_found';
  end if;
  if d.a_player = p_player then
    raise exception 'own_duel';
  end if;
  if d.b_player is not null then
    if d.b_player = p_player then
      raise exception 'already_joined';
    end if;
    raise exception 'taken';
  end if;
  update public.duels x
     set b_player = p_player, b_name = v_name, b_secret = v_secret, b_status = 'playing'
   where x.code = d.code;
  return v_secret;
end;
$$;

create or replace function public.save_duel(p_code text, p_secret uuid, p_tiers smallint[], p_answers text[], p_done boolean)
returns integer
language plpgsql security definer set search_path = public
as $$
declare
  d       public.duels;
  v_n     integer := coalesce(array_length(p_tiers, 1), 0);
  v_score integer := 0;
  v_tier  smallint;
  v_ans   text;
  v_pts   integer[] := array[10, 30, 55, 80, 100];
begin
  if p_tiers is null or p_answers is null or v_n > 5 or coalesce(array_length(p_answers, 1), 0) <> v_n then
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
  foreach v_ans in array p_answers loop
    if v_ans is null or char_length(v_ans) > 60 then
      raise exception 'bad_answers';
    end if;
  end loop;

  select * into d from public.duels x where x.code = upper(p_code) for update;
  if not found then
    raise exception 'not_found';
  end if;
  if d.live then
    raise exception 'not_allowed';
  end if;

  if d.a_secret = p_secret then
    if d.a_status <> 'playing' or coalesce(array_length(d.a_tiers, 1), 0) > v_n then
      raise exception 'not_allowed';
    end if;
    update public.duels x
       set a_tiers = p_tiers, a_answers = p_answers, a_score = v_score,
           a_status = case when p_done then 'done' else 'playing' end,
           a_done_at = case when p_done then now() else null end
     where x.code = d.code;
  elsif d.b_secret is not null and d.b_secret = p_secret then
    if d.b_status <> 'playing' or coalesce(array_length(d.b_tiers, 1), 0) > v_n then
      raise exception 'not_allowed';
    end if;
    update public.duels x
       set b_tiers = p_tiers, b_answers = p_answers, b_score = v_score,
           b_status = case when p_done then 'done' else 'playing' end,
           b_done_at = case when p_done then now() else null end
     where x.code = d.code;
  else
    raise exception 'not_allowed';
  end if;
  return v_score;
end;
$$;

-- Duell lesen (Ergebnis-Ansicht, Historie). Neu: ob es live gespielt wurde und ob jemand eine weitere
-- Runde ("Nochmal") geöffnet hat.
create or replace function public.get_duel(p_code text, p_player text)
returns json
language plpgsql security definer set search_path = public stable
as $$
declare
  d      public.duels;
  v_role text;
  v_fin  boolean;
begin
  select * into d from public.duels x where x.code = upper(p_code);
  if not found then
    return null;
  end if;
  v_role := case when d.a_player = p_player then 'a'
                 when d.b_player is not null and d.b_player = p_player then 'b'
                 else null end;
  v_fin := d.a_status = 'done' and coalesce(d.b_status, '') = 'done';
  return json_build_object(
    'code', d.code,
    'qids', d.qids,
    'role', v_role,
    'final', v_fin,
    'live', d.live,
    'rematch', (select json_build_object('code', n.code, 'room', n.room, 'by_pid', public.hh_pid(n.host),
                                         'by', (select k.name from public.accounts k where k.player_id = n.host))
                  from public.lobbies l join public.lobbies n on n.code = l.next_code
                 where l.code = d.code and n.q_at is null),
    'a', json_build_object(
      'name', d.a_name, 'pid', public.hh_pid(d.a_player), 'status', d.a_status, 'n', coalesce(array_length(d.a_tiers, 1), 0),
      'tiers',   case when v_fin or v_role = 'a' then to_json(d.a_tiers) end,
      'answers', case when v_fin or v_role = 'a' then to_json(d.a_answers) end,
      'score',   case when v_fin or v_role = 'a' then d.a_score end),
    'b', case when d.b_name is null then null else json_build_object(
      'name', d.b_name, 'pid', public.hh_pid(d.b_player), 'status', d.b_status, 'n', coalesce(array_length(d.b_tiers, 1), 0),
      'tiers',   case when v_fin or v_role = 'b' then to_json(d.b_tiers) end,
      'answers', case when v_fin or v_role = 'b' then to_json(d.b_answers) end,
      'score',   case when v_fin or v_role = 'b' then d.b_score end) end
  );
end;
$$;

revoke all on function public.hh_lobby_ms(text) from public, anon, authenticated;
revoke all on function public.hh_lobby_rank(text) from public, anon, authenticated;
revoke all on function public.hh_lobby_finish(text) from public, anon, authenticated;
revoke all on function public.hh_lobby_tick(text, text, boolean) from public, anon, authenticated;
revoke all on function public.hh_lobby_json(public.lobbies, text) from public, anon, authenticated;
revoke all on function public.hh_lobby_drop(text, text) from public, anon, authenticated;
revoke all on function public.hh_lobby_sweep() from public, anon, authenticated;
revoke all on function public.lobby_create(text, text[], boolean, integer, integer) from public;
revoke all on function public.lobby_settings(text, text, integer, boolean, integer) from public;
revoke all on function public.lobby_join(text, text) from public;
revoke all on function public.lobby_leave(text, text) from public;
revoke all on function public.lobby_kick(text, text, text) from public;
revoke all on function public.lobby_start(text, text) from public;
revoke all on function public.lobby_poll(text, text, boolean) from public;
revoke all on function public.lobby_answer(text, text, integer, smallint, text) from public;
revoke all on function public.lobby_again(text, text, text[]) from public;
revoke all on function public.lobby_list(text) from public;
revoke all on function public.lobby_stats(text, text) from public;
revoke all on function public.join_duel(text, text, text) from public;
revoke all on function public.save_duel(text, uuid, smallint[], text[], boolean) from public;
revoke all on function public.get_duel(text, text) from public;
grant execute on function public.lobby_create(text, text[], boolean, integer, integer) to anon, authenticated;
grant execute on function public.lobby_settings(text, text, integer, boolean, integer) to anon, authenticated;
grant execute on function public.lobby_join(text, text) to anon, authenticated;
grant execute on function public.lobby_leave(text, text) to anon, authenticated;
grant execute on function public.lobby_kick(text, text, text) to anon, authenticated;
grant execute on function public.lobby_start(text, text) to anon, authenticated;
grant execute on function public.lobby_poll(text, text, boolean) to anon, authenticated;
grant execute on function public.lobby_answer(text, text, integer, smallint, text) to anon, authenticated;
grant execute on function public.lobby_again(text, text, text[]) to anon, authenticated;
grant execute on function public.lobby_list(text) to anon, authenticated;
grant execute on function public.lobby_stats(text, text) to anon, authenticated;
grant execute on function public.join_duel(text, text, text) to anon, authenticated;
grant execute on function public.save_duel(text, uuid, smallint[], text[], boolean) to anon, authenticated;
grant execute on function public.get_duel(text, text) to anon, authenticated;

-- ============================================================
-- Teil 9 · Mehrspieler-Spiele in der Statistik
-- ============================================================
-- Spiele mit drei oder mehr Leuten zählen im Profil mit: Spiele, Siege, Siegquote, gewonnene Fragen,
-- Punkte, Nadeln, Serien und Historie. Sieg ist der alleinige erste Platz, ein geteilter erster Platz
-- zählt als Remis. Die Rangliste zählt die Siege ebenfalls mit. "Häufigste Gegner" bleibt beim 1 gegen 1.

-- Duell-Auswertung für beliebig viele Fragen (Lobbys zu zweit können 3 bis 10 Fragen haben).
create or replace function public.hh_duel_outcome(d public.duels)
returns table (wa integer, wb integer, sa integer, sb integer, winner text)
language plpgsql immutable
as $$
declare
  v_pts integer[] := array[10, 30, 55, 80, 100];
  ta integer;
  tb integer;
  aa text;
  ab text;
begin
  wa := 0; wb := 0; sa := 0; sb := 0;
  for i in 1..greatest(coalesce(cardinality(d.qids), 0), 1) loop
    ta := coalesce(d.a_tiers[i], -1);
    tb := coalesce(d.b_tiers[i], -1);
    aa := coalesce(d.a_answers[i], '');
    ab := coalesce(d.b_answers[i], '');
    if ta >= 0 and tb >= 0 and aa <> '' and lower(aa) = lower(ab) then
      continue;
    end if;
    if ta >= 0 then sa := sa + v_pts[ta + 1]; end if;
    if tb >= 0 then sb := sb + v_pts[tb + 1]; end if;
    if ta > tb then wa := wa + 1; elsif tb > ta then wb := wb + 1; end if;
  end loop;
  winner := case when wa > wb then 'a' when wb > wa then 'b'
                 when sa > sb then 'a' when sb > sa then 'b' else null end;
  return next;
end;
$$;

-- Profil lesen – jetzt mit den Mehrspieler-Spielen (in Zahlen und Historie; Historie mit Platz und Spielerzahl).
create or replace function public.get_profile(p_pid text, p_player text)
returns json
language plpgsql security definer set search_path = public stable
as $$
declare
  v_player text;
  v_me     boolean;
  v_today  date := (now() at time zone 'Europe/Berlin')::date;
  v_json   json;
begin
  if coalesce(p_pid, '') = '' then
    if p_player is null or char_length(p_player) not between 8 and 64 then
      return null;
    end if;
    v_player := p_player;
  else
    if p_pid !~ '^[0-9a-f]{12}$' then
      return null;
    end if;
    select x.p into v_player from (
      select k.player_id as p from public.accounts k where k.pid = p_pid
      union all
      select d.a_player from public.duels d where public.hh_pid(d.a_player) = p_pid
      union all
      select d.b_player from public.duels d where d.b_player is not null and public.hh_pid(d.b_player) = p_pid
      union all
      select s.player_id from public.scores s where public.hh_pid(s.player_id) = p_pid
    ) x limit 1;
    if v_player is null then
      return null;
    end if;
  end if;
  v_me := p_player is not null and p_player = v_player;

  with mine as (
    select d.code, d.created_at,
           d.a_player = v_player as is_a,
           (d.a_status = 'done' and coalesce(d.b_status, '') = 'done') as final,
           case when d.a_player = v_player then d.b_name else d.a_name end as opp_name,
           case when d.a_player = v_player
                then case when d.b_player is null then null else public.hh_pid(d.b_player) end
                else public.hh_pid(d.a_player) end as opp_pid,
           case when d.a_player = v_player then d.a_status else d.b_status end as my_status,
           case when d.a_player = v_player then d.b_status else d.a_status end as opp_status,
           case when d.a_player = v_player then d.a_tiers else d.b_tiers end as my_tiers,
           o.wa, o.wb, o.sa, o.sb, o.winner
      from public.duels d
      cross join lateral public.hh_duel_outcome(d) o
     where d.a_player = v_player or d.b_player = v_player
  ), r as (
    select m.code, m.created_at, m.final, m.opp_name, m.opp_pid, m.my_status, m.opp_status, m.my_tiers,
           case when not m.final then 'open'
                when m.winner is null then 'draw'
                when (m.winner = 'a') = m.is_a then 'win'
                else 'loss' end as result,
           case when m.is_a then m.wa else m.wb end as my_rounds,
           case when m.is_a then m.wb else m.wa end as opp_rounds,
           case when m.is_a then m.sa else m.sb end as my_pts,
           case when m.is_a then m.sb else m.sa end as opp_pts,
           2 as players, null::integer as place
      from mine m
    union all
    -- Mehrspieler-Spiele (ab 3 Spielern): Sieg, wer allein vorn liegt; geteilter erster Platz zählt als Remis.
    select l.code, l.created_at, true, null::text, null::text, 'done'::text, 'done'::text, p.tiers,
           case when p.won then 'win' when p.place = 1 then 'draw' else 'loss' end,
           coalesce(p.rounds, 0),
           coalesce((select sum(q.rounds) from public.lobby_players q where q.code = l.code and q.player <> v_player), 0)::integer,
           coalesce(p.pts, 0),
           (select max(q.pts) from public.lobby_players q where q.code = l.code and q.player <> v_player),
           l.n::integer, p.place
      from public.lobby_players p join public.lobbies l on l.code = p.code
     where p.player = v_player and l.done and l.n >= 3
  ), fin as (
    select r.result, r.created_at,
           row_number() over (order by r.created_at) - row_number() over (partition by r.result order by r.created_at) as grp,
           sum(case when r.result <> 'win' then 1 else 0 end) over (order by r.created_at desc) as breaks
      from r where r.final
  )
  select json_build_object(
    'pid', public.hh_pid(v_player),
    'me', v_me,
    'account', exists (select 1 from public.accounts k where k.player_id = v_player),
    'rename_next', case when v_me then (select (extract(epoch from k.name_changed_at + interval '7 days') * 1000)::bigint
                       from public.accounts k
                      where k.player_id = v_player and k.name_changed_at > now() - interval '7 days') end,
    'tokens', case when v_me then greatest(public.hh_tokens(v_player)
                 - coalesce((select k.spent from public.accounts k where k.player_id = v_player), 0), 0) end,
    'name_style', (select k.name_style from public.accounts k where k.player_id = v_player),
    'charm_l', (select k.charm_l from public.accounts k where k.player_id = v_player),
    'charm_r', (select k.charm_r from public.accounts k where k.player_id = v_player),
    'bonus', case when v_me then (
        select json_build_object('day', x.day, 'pos', x.pos, 'tokens', public.hh_day_bonus(x.pos))
          from (select s.day,
                       (select count(*) + 1 from public.scores s2
                         where s2.day = s.day and s2.name is not null and s2.score > s.score) as pos
                  from public.scores s
                 where s.player_id = v_player and s.name is not null and s.score > 0
                   and s.day < v_today and s.day >= v_today - 7
                 order by s.day desc limit 1) x) end,
    'avatar', (select k.avatar from public.accounts k where k.player_id = v_player),
    'xp', public.hh_xp(v_player),
    'free', (select json_build_object('rounds', k.free_rounds, 'best', k.free_best, 'needles', k.free_needles)
               from public.accounts k where k.player_id = v_player),
    'name', coalesce((select k.name from public.accounts k where k.player_id = v_player), (select x.n from (
        select d.a_name as n, d.created_at as t from public.duels d where d.a_player = v_player
        union all
        select d.b_name, d.created_at from public.duels d where d.b_player = v_player and d.b_name is not null
        union all
        select s.name, s.started_at from public.scores s where s.player_id = v_player and s.name is not null
      ) x order by x.t desc limit 1)),
    'since', (select (extract(epoch from min(x.t)) * 1000)::bigint from (
        select d.created_at as t from public.duels d where d.a_player = v_player or d.b_player = v_player
        union all
        select s.started_at from public.scores s where s.player_id = v_player
        union all
        select k.created_at from public.accounts k where k.player_id = v_player
      ) x),
    'duels', (select json_build_object(
        'played',      count(*) filter (where r.final),
        'wins',        count(*) filter (where r.result = 'win'),
        'losses',      count(*) filter (where r.result = 'loss'),
        'draws',       count(*) filter (where r.result = 'draw'),
        'open',        count(*) filter (where not r.final),
        'rounds_won',  coalesce(sum(r.my_rounds) filter (where r.final), 0),
        'rounds_lost', coalesce(sum(r.opp_rounds) filter (where r.final), 0),
        'avg_pts',     round(avg(r.my_pts) filter (where r.final)),
        'best_pts',    max(r.my_pts) filter (where r.final),
        'needles',     (select count(*) from r r2, unnest(r2.my_tiers) t where t = 4),
        'streak',      (select count(*) from fin f where f.breaks = 0),
        'best_streak', (select coalesce(max(z.c), 0) from (select count(*) as c from fin f where f.result = 'win' group by f.grp) z)
      ) from r),
    'history', (select coalesce(json_agg(h order by h.t desc), '[]'::json) from (
        select r.code, (extract(epoch from r.created_at) * 1000)::bigint as t, r.result,
               r.opp_name, r.opp_pid, r.my_status, r.opp_status,
               case when r.final then r.my_rounds end as my_rounds,
               case when r.final then r.opp_rounds end as opp_rounds,
               case when r.final then r.my_pts end as my_pts,
               case when r.final then r.opp_pts end as opp_pts,
               r.players, r.place
          from r
         where r.final or v_me
         order by r.created_at desc
         limit 30
      ) h),
    'rivals', (select coalesce(json_agg(x order by x.games desc, x.wins desc), '[]'::json) from (
        select r.opp_pid as pid, max(r.opp_name) as name, count(*) as games,
               count(*) filter (where r.result = 'win') as wins,
               count(*) filter (where r.result = 'loss') as losses
          from r
         where r.final and r.opp_pid is not null
         group by r.opp_pid
         order by count(*) desc
         limit 5
      ) x),
    'daily', (select json_build_object(
        'played', count(*),
        'avg',    round(avg(s.score)),
        'best',   max(s.score),
        'wins',   count(*) filter (where s.day < v_today and s.name is not null and s.score > 0 and s.score =
                    (select max(s2.score) from public.scores s2 where s2.day = s.day and s2.name is not null)),
        'needles', (select count(*) from public.scores s3, unnest(s3.tiers) t where s3.player_id = v_player and t = 4)
      ) from public.scores s
      where s.player_id = v_player and (s.status = 'done' or s.day < v_today))
  ) into v_json;
  return v_json;
end;
$$;

-- Rangliste: Siege aus Duellen und Mehrspieler-Spielen.
create or replace function public.get_ranking(p_player text)
returns json
language plpgsql security definer set search_path = public stable
as $$
declare
  v_json json;
begin
  with x as (
    select k.pid, k.name, public.hh_xp(k.player_id) as xp,
           (p_player is not null and k.player_id = p_player) as me,
           (select count(*)
              from public.duels d cross join lateral public.hh_duel_outcome(d) o
             where d.a_status = 'done' and coalesce(d.b_status, '') = 'done'
               and ((d.a_player = k.player_id and o.winner = 'a') or (d.b_player = k.player_id and o.winner = 'b')))
           + (select count(*)
                from public.lobby_players p join public.lobbies l on l.code = p.code
               where p.player = k.player_id and p.won and l.done and l.n >= 3) as wins
      from public.accounts k
  ), y as (
    select x.*, rank() over (order by x.xp desc) as pos from x
  )
  select json_build_object(
    'count', (select count(*) from y),
    'top', (select coalesce(json_agg(t order by t.pos, t.name), '[]'::json)
              from (select y.pid, y.name, y.xp, y.wins, y.me, y.pos from y order by y.pos, y.name limit 50) t),
    'me', (select row_to_json(t) from (select y.pid, y.name, y.xp, y.wins, y.pos from y where y.me limit 1) t)
  ) into v_json;
  return v_json;
end;
$$;

revoke all on function public.hh_duel_outcome(public.duels) from public, anon, authenticated;
revoke all on function public.get_profile(text, text) from public;
revoke all on function public.get_ranking(text) from public;
grant execute on function public.get_profile(text, text) to anon, authenticated;
grant execute on function public.get_ranking(text) to anon, authenticated;

-- Supabase die neuen Funktionen sofort bekannt machen.
notify pgrst, 'reload schema';
