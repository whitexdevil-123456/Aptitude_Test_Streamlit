

-- One-transaction exam submission for the Class Test Portal.
-- Run this in Supabase Dashboard -> SQL Editor BEFORE deploying the updated app.py.
-- The app calls public.submit_attempt_atomic(...) through the server-side secret key.

create or replace function public.submit_attempt_atomic(
    p_attempt_id uuid,
    p_answers jsonb default '[]'::jsonb,
    p_requested_status text default 'submitted'
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
    v_attempt public.attempts%rowtype;
    v_final_status text;
    v_score numeric(10,2) := 0;
    v_max_score numeric(10,2) := 0;
begin
    if p_requested_status not in ('submitted', 'expired') then
        raise exception 'Invalid requested status: %', p_requested_status;
    end if;

    if jsonb_typeof(coalesce(p_answers, '[]'::jsonb)) <> 'array' then
        raise exception 'p_answers must be a JSON array';
    end if;

    -- Lock the attempt so duplicate clicks/timeouts cannot finalize it twice.
    select * into v_attempt
      from public.attempts
     where id = p_attempt_id
     for update;

    if not found then
        raise exception 'Attempt % not found', p_attempt_id;
    end if;

    -- Idempotent response for a repeat click after a successful submission.
    if v_attempt.status <> 'in_progress' then
        return jsonb_build_object(
            'id', v_attempt.id,
            'status', v_attempt.status,
            'score', v_attempt.score,
            'max_score', v_attempt.max_score
        );
    end if;

    -- Reject any question ID not assigned to this attempt.
    if exists (
        select 1
          from jsonb_to_recordset(coalesce(p_answers, '[]'::jsonb)) as x(
              question_id bigint,
              answer_text text,
              code_answer text,
              output_answer text
          )
          left join public.attempt_questions aq
            on aq.attempt_id = p_attempt_id and aq.question_id = x.question_id
         where aq.question_id is null
    ) then
        raise exception 'Submitted answer includes a question not assigned to this attempt';
    end if;

    -- Persist all visible answers in one statement within this transaction.
    insert into public.answers (
        attempt_id, question_id, answer_text, code_answer, output_answer, updated_at
    )
    select
        p_attempt_id, x.question_id, x.answer_text, x.code_answer, x.output_answer, now()
      from jsonb_to_recordset(coalesce(p_answers, '[]'::jsonb)) as x(
          question_id bigint,
          answer_text text,
          code_answer text,
          output_answer text
      )
    on conflict (attempt_id, question_id) do update
       set answer_text = excluded.answer_text,
           code_answer = excluded.code_answer,
           output_answer = excluded.output_answer,
           updated_at = now();

    -- Grade objective answers. Coding answers without expected_output are left for teacher grading.
    with scoring as (
        select
            a.attempt_id,
            a.question_id,
            q.question_type,
            q.expected_output,
            aq.marks,
            case
                when q.question_type in ('mcq', 'short') then exists (
                    select 1
                      from unnest(string_to_array(coalesce(q.correct_answer, ''), '|')) as expected(value)
                     where lower(regexp_replace(btrim(coalesce(a.answer_text, '')), '[[:space:]]+', ' ', 'g'))
                           = lower(regexp_replace(btrim(expected.value), '[[:space:]]+', ' ', 'g'))
                )
                when q.question_type = 'coding' and nullif(btrim(coalesce(q.expected_output, '')), '') is not null then
                    btrim(regexp_replace(
                        replace(replace(coalesce(a.output_answer, ''), E'\r\n', E'\n'), E'\r', E'\n'),
                        E'[[:blank:]]+\n', E'\n', 'g'
                    )) = btrim(regexp_replace(
                        replace(replace(coalesce(q.expected_output, ''), E'\r\n', E'\n'), E'\r', E'\n'),
                        E'[[:blank:]]+\n', E'\n', 'g'
                    ))
                else null
            end as is_correct
        from public.attempt_questions aq
        join public.questions q on q.id = aq.question_id
        left join public.answers a
          on a.attempt_id = aq.attempt_id and a.question_id = aq.question_id
        where aq.attempt_id = p_attempt_id
    )
    update public.answers a
       set is_correct = scoring.is_correct,
           awarded_marks = case
               when scoring.question_type in ('mcq', 'short')
                   then case when scoring.is_correct then scoring.marks else 0 end
               when scoring.question_type = 'coding'
                    and nullif(btrim(coalesce(scoring.expected_output, '')), '') is not null
                   then case when scoring.is_correct then scoring.marks else 0 end
               else coalesce(a.awarded_marks, 0)
           end,
           updated_at = now()
      from scoring
     where a.attempt_id = scoring.attempt_id
       and a.question_id = scoring.question_id;

    select coalesce(sum(coalesce(a.awarded_marks, 0)), 0),
           coalesce(sum(aq.marks), 0)
      into v_score, v_max_score
      from public.attempt_questions aq
      left join public.answers a
        on a.attempt_id = aq.attempt_id and a.question_id = aq.question_id
     where aq.attempt_id = p_attempt_id;

    -- Enforce the server-side deadline; a late click is recorded as expired.
    v_final_status := case
        when p_requested_status = 'expired' or now() >= v_attempt.deadline_at then 'expired'
        else 'submitted'
    end;

    update public.attempts
       set status = v_final_status,
           submitted_at = now(),
           score = round(v_score, 2),
           max_score = round(v_max_score, 2)
     where id = p_attempt_id and status = 'in_progress';

    return jsonb_build_object(
        'id', p_attempt_id,
        'status', v_final_status,
        'score', round(v_score, 2),
        'max_score', round(v_max_score, 2)
    );
end;
$$;

revoke all on function public.submit_attempt_atomic(uuid, jsonb, text) from public;
revoke all on function public.submit_attempt_atomic(uuid, jsonb, text) from anon;
revoke all on function public.submit_attempt_atomic(uuid, jsonb, text) from authenticated;
grant execute on function public.submit_attempt_atomic(uuid, jsonb, text) to service_role;

notify pgrst, 'reload schema';
