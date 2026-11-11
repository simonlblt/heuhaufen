-- Heuhaufen: Spielerprofile, Match-Historie und Statistiken
-- Einmal komplett im Supabase "SQL Editor" einfügen und auf "Run" klicken.
-- Voraussetzung: supabase.sql und duell.sql wurden schon ausgeführt.
-- Das Skript kann gefahrlos mehrfach ausgeführt werden.

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
