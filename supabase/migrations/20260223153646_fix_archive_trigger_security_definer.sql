-- Fix RLS violation when inserting into archive with the anon/publishable key.
--
-- Problem: archive_after_insert() runs in the security context of the calling
-- role (anon). It writes to meetings, utterances, and meeting_summary_chunks,
-- but those tables only have SELECT policies for anon — no INSERT policies.
-- Every downstream write therefore fails with an RLS violation.
--
-- Fix: SECURITY DEFINER makes the function execute as its owner (postgres),
-- which bypasses RLS. This is the same pattern used by openai_embed().

CREATE OR REPLACE FUNCTION archive_after_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
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
    'Trigger function: processes a newly inserted archive row into meetings, utterances, and embeddings. '
    'SECURITY DEFINER so downstream writes to meetings/utterances bypass RLS.';
