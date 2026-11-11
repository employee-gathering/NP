-- Impostor Hunt: one final submission per team.
-- Team-code-only access cannot prove a participant's identity; keep team codes private.
-- This migration prevents duplicate/replacement submissions, but does not prevent
-- someone who knows another team's code from submitting on that team's behalf.

do $$
begin
  if exists (
    select team_id
    from public.ih_submissions
    group by team_id
    having count(*) > 1
  ) then
    raise exception 'Ada tim dengan lebih dari satu submission. Perlu pemeriksaan manual sebelum migrasi.';
  end if;
end;
$$;

create unique index if not exists ih_submissions_one_per_team
  on public.ih_submissions(team_id);

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
  if exists (select 1 from public.ih_submissions where team_id = v_team.id) then
    return jsonb_build_object('ok', false, 'message', 'Jawaban tim ini sudah tercatat. Hubungi panitia jika ada kesalahan.');
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


revoke all on function public.ih_submit_answer(text, text, text) from public;
grant execute on function public.ih_submit_answer(text, text, text) to anon, authenticated;
