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

-- Supabase die neuen Funktionen sofort bekannt machen.
notify pgrst, 'reload schema';
