-- Impostor Hunt QR backend
-- Apply this file in Supabase SQL Editor while connected as project owner.
-- Raw QR tokens are returned once to the admin and are never stored in the database.
-- This migration does not alter attendees, teams, missions, or puzzle assignments.

create or replace function public.ih_issue_qr_tokens(p_session_id uuid)
returns table(qr_type text, qr_label text, token text, qr_url text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_session public.ih_game_sessions%rowtype;
  v_player record;
  v_ride record;
  v_token text;
  v_base_url constant text := 'https://employee-gathering.github.io/NP/';
begin
  if auth.uid() is null or not public.is_admin() then
    raise exception 'Akses hanya untuk admin.';
  end if;

  select * into v_session
  from public.ih_game_sessions
  where id = p_session_id
  for update;

  if not found then raise exception 'Sesi tidak ditemukan.'; end if;
  if v_session.status <> 'draft' then
    raise exception 'QR hanya dapat dibuat saat sesi masih draft.';
  end if;
  if exists (select 1 from public.ih_qr_codes where session_id = p_session_id) then
    raise exception 'QR sesi ini sudah pernah dibuat. Jangan menerbitkan ulang token.';
  end if;
  if (select count(*) from public.ih_players where session_id = p_session_id and active) <> 18 then
    raise exception 'Sesi harus memiliki tepat 18 pemain aktif.';
  end if;
  if (select count(*) from public.ih_rides where active) <> 18 then
    raise exception 'Harus tersedia tepat 18 wahana aktif.';
  end if;
  if (select count(*) from public.ih_missions m join public.ih_teams t on t.id=m.team_id where t.session_id=p_session_id) <> 108 then
    raise exception 'Misi belum lengkap: harus ada 108 misi.';
  end if;
  if (select count(*) from public.ih_puzzle_config pc join public.ih_teams t on t.id=pc.team_id where t.session_id=p_session_id and pc.configured) <> 18 then
    raise exception 'Teka-teki 18 tim belum lengkap.';
  end if;

  for v_player in
    select id, player_number, color_code
    from public.ih_players
    where session_id = p_session_id and active
    order by player_number
  loop
    v_token := encode(extensions.gen_random_bytes(32), 'hex');
    insert into public.ih_qr_codes(session_id, qr_type, player_id, token_hash)
    values (p_session_id, 'player', v_player.id,
            encode(extensions.digest(v_token, 'sha256'), 'hex'));
    qr_type := 'player';
    qr_label := 'Pemain ' || lpad(v_player.player_number::text, 2, '0') || ' - ' || v_player.color_code;
    token := v_token;
    qr_url := v_base_url || '?qr=' || v_token;
    return next;
  end loop;

  for v_ride in
    select id, ride_name from public.ih_rides where active order by ride_name
  loop
    v_token := encode(extensions.gen_random_bytes(32), 'hex');
    insert into public.ih_qr_codes(session_id, qr_type, ride_id, token_hash)
    values (p_session_id, 'ride', v_ride.id,
            encode(extensions.digest(v_token, 'sha256'), 'hex'));
    qr_type := 'ride';
    qr_label := 'Wahana - ' || v_ride.ride_name;
    token := v_token;
    qr_url := v_base_url || '?qr=' || v_token;
    return next;
  end loop;
end;
$$;

create or replace function public.ih_start_game(p_session_id uuid)
returns timestamptz
language plpgsql
security definer
set search_path = public
as $$
declare
  v_started timestamptz;
begin
  if auth.uid() is null or not public.is_admin() then
    raise exception 'Akses hanya untuk admin.';
  end if;
  perform 1 from public.ih_game_sessions where id = p_session_id for update;
  if not found then raise exception 'Sesi tidak ditemukan.'; end if;
  if (select status from public.ih_game_sessions where id = p_session_id) <> 'draft' then
    raise exception 'Sesi harus berstatus draft untuk dimulai.';
  end if;
  if (select count(*) from public.ih_qr_codes where session_id = p_session_id) <> 36 then
    raise exception 'Buat 36 QR terlebih dahulu.';
  end if;
  if (select count(*) from public.ih_team_progress p join public.ih_teams t on t.id=p.team_id where t.session_id = p_session_id) <> 108 then
    raise exception 'Progres 108 misi belum tersedia.';
  end if;

  v_started := now();
  update public.ih_game_settings
  set game_started_at = v_started, game_ended_at = null, updated_at = now()
  where session_id = p_session_id;
  update public.ih_game_sessions
  set status = 'running', updated_at = now()
  where id = p_session_id;
  return v_started;
end;
$$;

create or replace function public.ih_scan_qr(p_team_code text, p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_team public.ih_teams%rowtype;
  v_session public.ih_game_sessions%rowtype;
  v_qr public.ih_qr_codes%rowtype;
  v_progress public.ih_team_progress%rowtype;
  v_ride_name text;
  v_letter text;
  v_delay integer;
  v_started timestamptz;
begin
  if coalesce(length(p_token), 0) <> 64 then
    return jsonb_build_object('ok', false, 'code', 'invalid_token', 'message', 'QR tidak valid.');
  end if;
  select * into v_team from public.ih_teams where team_code = upper(trim(p_team_code));
  if not found then
    return jsonb_build_object('ok', false, 'code', 'invalid_team', 'message', 'Kode tim tidak ditemukan.');
  end if;

  perform 1 from public.ih_teams where id = v_team.id for update;
  select * into v_session from public.ih_game_sessions where id = v_team.session_id;
  select * into v_qr from public.ih_qr_codes
  where token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
    and active;

  if not found or v_qr.session_id <> v_team.session_id then
    insert into public.ih_scan_logs(session_id, team_id, scan_result, detail)
    values (v_team.session_id, v_team.id, 'invalid', '{"reason":"invalid_or_other_batch_token"}'::jsonb);
    return jsonb_build_object('ok', false, 'code', 'invalid_qr', 'message', 'QR tidak valid untuk batch ini.');
  end if;

  if v_session.status <> 'running' then
    return jsonb_build_object('ok', false, 'code', 'not_running', 'message', 'Permainan belum dimulai.');
  end if;

  select player_search_delay_seconds, game_started_at
  into v_delay, v_started
  from public.ih_game_settings where session_id = v_team.session_id;

  if v_started is null or now() < v_started + make_interval(secs => v_delay) then
    return jsonb_build_object('ok', false, 'code', 'start_delay',
      'message', 'Tunggu aba-aba admin. Permainan dimulai 30 detik setelah dimulai.');
  end if;

  if v_qr.qr_type = 'player' then
    select * into v_progress
    from public.ih_team_progress
    where team_id = v_team.id
      and color_code = (select color_code from public.ih_players where id = v_qr.player_id)
    for update;

    if not found then
      return jsonb_build_object('ok', false, 'code', 'no_mission', 'message', 'Misi warna ini tidak ditemukan.');
    end if;
    if v_progress.status = 'letter_found' then
      return jsonb_build_object('ok', false, 'code', 'already_completed', 'message', 'Misi warna ini sudah selesai.');
    end if;
    if exists (select 1 from public.ih_team_progress where team_id = v_team.id and status = 'player_found') then
      return jsonb_build_object('ok', false, 'code', 'finish_current', 'message', 'Selesaikan misi yang sedang berjalan terlebih dahulu.');
    end if;

    update public.ih_team_progress
    set status = 'player_found', player_scanned_at = now(), updated_at = now()
    where id = v_progress.id;
    select ride_name into v_ride_name from public.ih_rides where id = v_progress.assigned_ride_id;
    insert into public.ih_scan_logs(session_id, team_id, qr_code_id, scan_result, detail)
    values (v_team.session_id, v_team.id, v_qr.id, 'player_ok',
            jsonb_build_object('color', v_progress.color_code));
    return jsonb_build_object('ok', true, 'code', 'player_ok',
      'color_code', v_progress.color_code, 'ride_name', v_ride_name,
      'message', 'Cari wahana yang ditugaskan untuk warna ini.');
  end if;

  select * into v_progress
  from public.ih_team_progress
  where team_id = v_team.id and status = 'player_found'
  for update;

  if not found then
    return jsonb_build_object('ok', false, 'code', 'scan_player_first',
      'message', 'Pindai QR pemain berkostum terlebih dahulu.');
  end if;

  if v_qr.ride_id <> v_progress.assigned_ride_id then
    insert into public.ih_scan_logs(session_id, team_id, qr_code_id, scan_result, detail)
    values (v_team.session_id, v_team.id, v_qr.id, 'wrong_ride',
            jsonb_build_object('color', v_progress.color_code));
    update public.ih_team_progress
    set status = 'waiting', player_scanned_at = null, updated_at = now()
    where id = v_progress.id;
    return jsonb_build_object('ok', false, 'code', 'wrong_ride',
      'message', 'Belum tepat. Pindai QR pemain berkostum lagi untuk mendapatkan petunjuk.');
  end if;

  select letter into v_letter
  from public.ih_puzzle_letters
  where team_id = v_team.id and color_code = v_progress.color_code;

  update public.ih_team_progress
  set status = 'letter_found', ride_scanned_at = now(),
      letter_received = v_letter, updated_at = now()
  where id = v_progress.id;

  insert into public.ih_scan_logs(session_id, team_id, qr_code_id, scan_result, detail)
  values (v_team.session_id, v_team.id, v_qr.id, 'ride_ok',
          jsonb_build_object('color', v_progress.color_code));

  return jsonb_build_object('ok', true, 'code', 'ride_ok',
    'color_code', v_progress.color_code, 'letter', v_letter,
    'message', 'Benar! Satu huruf berhasil dikumpulkan.');
end;
$$;

create or replace function public.ih_get_team_state(p_team_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_team public.ih_teams%rowtype;
  v_session public.ih_game_sessions%rowtype;
begin
  select * into v_team from public.ih_teams where team_code = upper(trim(p_team_code));
  if not found then
    return jsonb_build_object('ok', false, 'message', 'Kode tim tidak ditemukan.');
  end if;
  select * into v_session from public.ih_game_sessions where id = v_team.session_id;
  return jsonb_build_object(
    'ok', true,
    'team_code', v_team.team_code,
    'team_name', v_team.team_name,
    'batch_code', (select batch_code from public.ih_game_sessions where id = v_team.session_id),
    'session_status', v_session.status,
    'progress', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'color_code', p.color_code, 'status', p.status, 'letter', p.letter_received
      ) order by c.sort_order), '[]'::jsonb)
      from public.ih_team_progress p
      join public.ih_colors c on c.code = p.color_code
      where p.team_id = v_team.id
    )
  );
end;
$$;

create or replace function public.ih_submit_answer(
  p_team_code text,
  p_animal_answer text,
  p_impostor_color_code text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_team public.ih_teams%rowtype;
  v_session public.ih_game_sessions%rowtype;
  v_answer text;
  v_impostor text;
  v_elapsed integer;
  v_correct boolean;
begin
  select * into v_team from public.ih_teams where team_code = upper(trim(p_team_code));
  if not found then
    return jsonb_build_object('ok', false, 'message', 'Kode tim tidak ditemukan.');
  end if;
  perform 1 from public.ih_teams where id = v_team.id for update;
  select * into v_session from public.ih_game_sessions where id = v_team.session_id;

  if v_session.status <> 'running' then
    return jsonb_build_object('ok', false, 'message', 'Permainan tidak sedang berjalan.');
  end if;
  if (select count(*) from public.ih_team_progress where team_id = v_team.id and status = 'letter_found') <> 6 then
    return jsonb_build_object('ok', false, 'message', 'Kumpulkan keenam huruf terlebih dahulu.');
  end if;

  select animal_answer, impostor_color_code
  into v_answer, v_impostor
  from public.ih_puzzle_config
  where team_id = v_team.id and configured;

  if v_answer is null then raise exception 'Konfigurasi teka-teki belum tersedia.'; end if;
  v_correct := upper(trim(p_animal_answer)) = v_answer
    and upper(trim(p_impostor_color_code)) = v_impostor;

  select greatest(0, floor(extract(epoch from (now() - game_started_at)))::integer)
  into v_elapsed
  from public.ih_game_settings
  where session_id = v_team.session_id;

  insert into public.ih_submissions(
    session_id, team_id, animal_answer, impostor_color_code, is_correct, elapsed_seconds
  )
  values (
    v_team.session_id, v_team.id, upper(trim(p_animal_answer)),
    upper(trim(p_impostor_color_code)), v_correct, v_elapsed
  );

  return jsonb_build_object(
    'ok', true,
    'correct', v_correct,
    'message', case when v_correct
      then 'Jawaban benar! Tim berhasil menyelesaikan misi.'
      else 'Jawaban belum tepat. Periksa kembali hewan dan warna impostor.'
    end
  );
end;
$$;

revoke all on function public.ih_scan_qr(text, text) from public;
revoke all on function public.ih_get_team_state(text) from public;
revoke all on function public.ih_submit_answer(text, text, text) from public;
revoke all on function public.ih_issue_qr_tokens(uuid) from public;
revoke all on function public.ih_start_game(uuid) from public;

grant execute on function public.ih_scan_qr(text, text) to anon, authenticated;
grant execute on function public.ih_get_team_state(text) to anon, authenticated;
grant execute on function public.ih_submit_answer(text, text, text) to anon, authenticated;
grant execute on function public.ih_issue_qr_tokens(uuid) to authenticated;
grant execute on function public.ih_start_game(uuid) to authenticated;
