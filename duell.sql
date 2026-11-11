-- Heuhaufen: Duell per Link (1 gegen 1)
-- Einmal komplett im Supabase "SQL Editor" einfügen und auf "Run" klicken.
-- Das Skript kann gefahrlos mehrfach ausgeführt werden.

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

-- Supabase die neuen Funktionen sofort bekannt machen.
notify pgrst, 'reload schema';
