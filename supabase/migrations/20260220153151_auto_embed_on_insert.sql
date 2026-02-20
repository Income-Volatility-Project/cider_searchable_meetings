-- Migration: auto-embed meetings and utterances on archive insert
--
-- Replaces archive_after_insert() to also call embed_meeting() and
-- embed_utterances() after the transcript/summary processing completes.
-- This ensures meeting_summary_chunks and utterances.embedding are
-- populated automatically whenever a new archive row is inserted.

CREATE OR REPLACE FUNCTION archive_after_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM process_summary(NEW.meeting_id);
    PERFORM process_transcript(NEW.meeting_id);
    PERFORM embed_meeting(NEW.meeting_id);
    PERFORM embed_utterances(NEW.meeting_id);
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION archive_after_insert() IS
    'Trigger function: processes a newly inserted archive row into meetings, utterances, and embeddings';
