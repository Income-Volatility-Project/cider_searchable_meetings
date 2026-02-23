-- Background embeddings via pg_cron
--
-- Problem: archive_after_insert() called embed_meeting() and embed_utterances()
-- synchronously, blocking the INSERT until all OpenAI API calls finished
-- (potentially minutes for meetings with hundreds of utterances).
--
-- Fix: remove the embed calls from the trigger and schedule a pg_cron job
-- every 10 minutes that calls embed_all_meetings() + embed_all_utterances().
-- Those functions already skip rows where embedding IS NOT NULL, so they're
-- idempotent and resumable.
--
-- Concurrency safety: FOR UPDATE SKIP LOCKED added to the inner loops so
-- if a second cron job fires before the first finishes, each job processes
-- a disjoint set of rows rather than duplicating work.


-- ── 1. Enable pg_cron ────────────────────────────────────────────────────────

CREATE EXTENSION IF NOT EXISTS pg_cron;


-- ── 2. Remove embed calls from archive_after_insert ─────────────────────────

CREATE OR REPLACE FUNCTION archive_after_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    PERFORM process_summary(NEW.meeting_id);
    PERFORM process_transcript(NEW.meeting_id);
    -- embed_meeting() and embed_utterances() are now handled by the
    -- embed-pending pg_cron job (runs every 10 minutes).
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION archive_after_insert() IS
    'Trigger function: processes a newly inserted archive row into meetings and utterances. '
    'Embeddings are generated asynchronously by the embed-pending pg_cron job. '
    'SECURITY DEFINER so downstream writes to meetings/utterances bypass RLS.';


-- ── 3. Add FOR UPDATE SKIP LOCKED to embed_utterances inner loop ─────────────
-- Concurrent cron jobs calling embed_utterances for the same meeting will now
-- each pick up different utterances rather than making duplicate OpenAI calls.

CREATE OR REPLACE FUNCTION embed_utterances(p_meeting_id TEXT)
RETURNS TABLE (utterances_embedded INTEGER, success BOOLEAN, error_message TEXT)
LANGUAGE plpgsql
AS $$
DECLARE
    v_count     INTEGER := 0;
    v_utterance RECORD;
BEGIN
    BEGIN
        FOR v_utterance IN
            SELECT id, text
            FROM   utterances
            WHERE  meeting_id = p_meeting_id
              AND  embedding IS NULL
            FOR UPDATE SKIP LOCKED
        LOOP
            UPDATE utterances
            SET    embedding = openai_embed(v_utterance.text)
            WHERE  id = v_utterance.id;

            v_count := v_count + 1;
        END LOOP;

        RETURN QUERY SELECT v_count, true, NULL::TEXT;

    EXCEPTION WHEN OTHERS THEN
        RETURN QUERY SELECT v_count, false, SQLERRM;
    END;
END;
$$;

COMMENT ON FUNCTION embed_utterances(TEXT) IS
    'Generate embeddings for every utterance in a meeting that does not yet '
    'have an embedding. Resumable and concurrency-safe (FOR UPDATE SKIP LOCKED).';


-- ── 4. Add FOR UPDATE SKIP LOCKED to embed_all_meetings outer loop ───────────
-- Concurrent cron jobs will each claim different meetings and process them in
-- parallel, which is beneficial for large batches.

CREATE OR REPLACE FUNCTION embed_all_meetings()
RETURNS TABLE (meeting_id TEXT, success BOOLEAN, error_message TEXT)
LANGUAGE plpgsql
AS $$
DECLARE
    v_meeting RECORD;
    v_result  RECORD;
BEGIN
    FOR v_meeting IN
        SELECT m.meeting_id
        FROM   meetings m
        WHERE  m.short_summary_embedding IS NULL
        FOR UPDATE SKIP LOCKED
    LOOP
        SELECT * INTO v_result FROM embed_meeting(v_meeting.meeting_id);
        RETURN QUERY SELECT v_meeting.meeting_id, v_result.success, v_result.error_message;
    END LOOP;
END;
$$;

COMMENT ON FUNCTION embed_all_meetings() IS
    'Batch-embed all meetings that do not yet have a short_summary_embedding. '
    'Concurrency-safe: FOR UPDATE SKIP LOCKED lets concurrent cron jobs process '
    'different meetings in parallel.';


-- ── 5. Create embed_pending wrapper ──────────────────────────────────────────

CREATE OR REPLACE FUNCTION embed_pending()
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    PERFORM * FROM embed_all_meetings();
    PERFORM * FROM embed_all_utterances();
END;
$$;

COMMENT ON FUNCTION embed_pending() IS
    'Called by the embed-pending pg_cron job every 10 minutes. '
    'Embeds all meetings and utterances that are missing embeddings.';


-- ── 6. Schedule pg_cron job ──────────────────────────────────────────────────
-- Guard: unschedule first so this migration is idempotent on re-run.

SELECT cron.unschedule('embed-pending')
FROM   cron.job
WHERE  jobname = 'embed-pending';

SELECT cron.schedule('embed-pending', '*/10 * * * *', 'SELECT embed_pending()');
