# Apply the atomic submission fix

The updated app uses a PostgreSQL function named `submit_attempt_atomic` to save the student's current answers, calculate the score, and update `attempts.status` in a single database transaction. This is designed to prevent partial submits and reduce round trips.

## 1. Update Supabase first

Because your database already exists, open **Supabase Dashboard → SQL Editor**, paste the complete contents of `submit_attempt_rpc.sql`, and run it. Wait for a successful result. Do this before uploading the app update.

If the SQL fails, do not deploy the app yet. Resolve the SQL error first.

## 2. Update the app

Replace the repository's root `app.py` with the supplied new `app.py`, commit, and push to the branch that Streamlit Community Cloud deploys. Wait for redeployment.

The app sidebar must show this build identifier:

`2026-10-24-atomic-submit-v3`

If it does not appear, the deployment is still running older code or is configured to a different repository/branch/main-file path.

## 3. Verify database status

After submitting a test, run this in Supabase SQL Editor:

```sql
select id, student_id, category, status, submitted_at, score, max_score
from public.attempts
order by started_at desc
limit 30;
```

A successful attempt should have `status = 'submitted'` and a non-null `submitted_at`. If the server accepts the attempt after its deadline, it will be recorded as `expired` by design.

## 4. If the submit fails

Read the error displayed on the student's page and the Streamlit Cloud app logs. A missing `submit_attempt_atomic` function means Step 1 was skipped or the SQL function was not created in the same Supabase project. An API-key error means app Secrets still contain the wrong key/URL pair.

## Load note

The exam clock refreshes every 10 seconds rather than every second, and repeated reads of static attempt/question data are cached briefly. This reduces load but is not a capacity guarantee. Run a concurrent pilot with representative test accounts before a real exam. Streamlit Community Cloud resource allocations can vary and may throttle apps.
