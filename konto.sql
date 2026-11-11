-- Heuhaufen: Profile mit Name und Passwort (Anmeldung auf jedem Gerät)
-- Einmal komplett im Supabase "SQL Editor" einfügen und auf "Run" klicken.
-- Voraussetzung: supabase.sql, duell.sql und profil.sql wurden schon ausgeführt.
-- Das Skript kann gefahrlos mehrfach ausgeführt werden.

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
