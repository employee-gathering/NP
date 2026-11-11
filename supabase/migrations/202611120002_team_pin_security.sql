-- Per-team access PINs for Impostor Hunt
-- Run after 202611120001_impostor_hunt_qr_backend.sql.
-- PINs are 12-digit cryptographically random values. Only hashes are stored.
-- Raw PINs are returned once to an admin and must be saved securely.

alter table public.ih_teams
  add column if not exists access_pin_hash text,
  add column if not exists pin_failed_attempts integer not null default 0,
  add column if not exists pin_locked_until timestamptz;

create or replace function public.ih_issue_team_pins(p_session_id uuid)
returns table(team_code text, team_name text, access_pin text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_team record;
  v_pin text;
begin
  if auth.uid() is null or not public.is_admin() then
    raise exception 'Akses hanya untuk admin.';
  end if;

  perform 1 from public.ih_game_sessions
  where id = p_session_id and status = 'draft'
  for update;
  if not found then
    raise exception 'Sesi tidak ditemukan atau bukan berstatus draft.';
  end if;

  if (select count(*) from public.ih_teams where session_id = p_session_id) <> 18 then
    raise exception 'Sesi harus memiliki tepat 18 tim.';
  end if;

  if exists (
    select 1 from public.ih_teams
    where session_id = p_session_id and access_pin_hash is not null
  ) then
    raise exception 'PIN tim sesi ini sudah pernah dibuat. Tidak diterbitkan ulang.';
  end if;

  for v_team in
    select id, ih_teams.team_code as code, ih_teams.team_name as name
    from public.ih_teams
    where session_id = p_session_id
    order by team_number
  loop
    v_pin := lpad(
      (('x' || encode(extensions.gen_random_bytes(7), 'hex'))::bit(56)::bigint
        % 1000000000000)::text,
      12,
      '0'
    );

    update public.ih_teams
    set access_pin_hash = encode(extensions.digest(v_pin, 'sha256'), 'hex'),
        pin_failed_attempts = 0,
        pin_locked_until = null
    where id = v_team.id;

    team_code := v_team.code;
    team_name := v_team.name;
    access_pin := v_pin;
    return next;
  end loop;
end;
$$;

create or replace function public.ih_team_pin_valid(p_team_code text, p_pin text)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_team public.ih_teams%rowtype;
begin
  if coalesce(length(p_pin), 0) <> 12 or p_pin !~ '^[0-9]{12}$' then
    return false;
  end if;

  select * into v_team
  from public.ih_teams
  where team_code = upper(trim(p_team_code))
  for update;

  if not found or v_team.access_pin_hash is null then
    return false;
  end if;

  if v_team.pin_locked_until is not null and v_team.pin_locked_until > now() then
    return false;
  end if;

  if v_team.access_pin_hash = encode(extensions.digest(p_pin, 'sha256'), 'hex') then
    update public.ih_teams
    set pin_failed_attempts = 0, pin_locked_until = null
    where id = v_team.id;
    return true;
  end if;

  update public.ih_teams
  set pin_failed_attempts = pin_failed_attempts + 1,
      pin_locked_until = case
        when pin_failed_attempts + 1 >= 5 then now() + interval '15 minutes'
        else pin_locked_until
      end
  where id = v_team.id;

  return false;
end;
$$;

-- Replace the unauthenticated team-code-only RPC signatures with PIN-protected versions.
drop function if exists public.ih_scan_qr(text, text);
drop function if exists public.ih_get_team_state(text);
drop function if exists public.ih_submit_answer(text, text, text);

create or replace function public.ih_scan_qr(
  p_team_code text,
  p_pin text,
  p_token text
)
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
  select * into v_team
  from public.ih_teams
  where team_code = upper(trim(p_team_code));

  if not found then
    return jsonb_build_object('ok', false, 'code', 'invalid_team', 'message', 'Kode tim atau PIN tidak valid.');
  end if;

  if not public.ih_team_pin_valid(p_team_code, p_pin) then
    return jsonb_build_object('ok', false, 'code', 'invalid_pin', 'message', 'Kode tim atau PIN salah, atau akses sementara dikunci.');
  end if;

  if coalesce(length(p_token), 0) <> 64 then
    return jsonb_build_object('ok', false, 'code', 'invalid_token', 'message', 'QR tidak valid.');
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

create or replace function public.ih_get_team_state(p_team_code text, p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_team public.ih_teams%rowtype;
  v_session public.ih_game_sessions%rowtype;
begin
  select * into v_team
  from public.ih_teams
  where team_code = upper(trim(p_team_code));

  if not found or not public.ih_team_pin_valid(p_team_code, p_pin) then
    return jsonb_build_object('ok', false, 'message', 'Kode tim atau PIN salah, atau akses sementara dikunci.');
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
  p_pin text,
  p_animal_answer text,
  p_impostor_color_code text
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_team public.ih_teams%rowtype;
  v_session public.ih_game_sessions%rowtype;
  v_answer text;
  v_impostor text;
  v_elapsed integer;
  v_correct boolean;
begin
  select * into v_team
  from public.ih_teams
  where team_code = upper(trim(p_team_code));

  if not found or not public.ih_team_pin_valid(p_team_code, p_pin) then
    return jsonb_build_object('ok', false, 'message', 'Kode tim atau PIN salah, atau akses sementara dikunci.');
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

revoke all on function public.ih_team_pin_valid(text, text) from public;
revoke all on function public.ih_issue_team_pins(uuid) from public;
revoke all on function public.ih_scan_qr(text, text, text) from public;
revoke all on function public.ih_get_team_state(text, text) from public;
revoke all on function public.ih_submit_answer(text, text, text, text) from public;

grant execute on function public.ih_issue_team_pins(uuid) to authenticated;
grant execute on function public.ih_scan_qr(text, text, text) to anon, authenticated;
grant execute on function public.ih_get_team_state(text, text) to anon, authenticated;
grant execute on function public.ih_submit_answer(text, text, text, text) to anon, authenticated;
