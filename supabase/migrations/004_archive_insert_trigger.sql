-- Trigger: auto-process archive inserts into meetings and utterances
--
-- When a row is inserted into archive, automatically call:
--   process_summary()    → upserts into meetings            (defined in 003)
--   process_transcript() → inserts into utterances          (defined in 002)
--
-- Embeddings are generated asynchronously by the embed-pending pg_cron job.
--
-- SECURITY DEFINER so downstream writes to meetings/utterances bypass RLS
-- (the trigger runs as postgres, not the calling role).

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

CREATE TRIGGER archive_insert_trigger
    AFTER INSERT ON archive
    FOR EACH ROW
    EXECUTE FUNCTION archive_after_insert();
