-- Run in Supabase SQL Editor after a test submission.
select id, student_id, category, status, submitted_at, score, max_score
from public.attempts
order by started_at desc
limit 30;

-- Confirm that the atomic submission function exists in the current project.
select routine_schema, routine_name, data_type
from information_schema.routines
where routine_schema = 'public'
  and routine_name = 'submit_attempt_atomic';
