-- Trigger: auto-process archive inserts into meetings and utterances
--
-- When a row is inserted into archive, automatically call:
--   process_summary()    → upserts into meetings   (defined in 003)
--   process_transcript() → inserts into utterances (defined in 002)
--
-- Both processing functions handle their own errors internally and never
-- raise exceptions, so a processing failure does not roll back the insert.

CREATE OR REPLACE FUNCTION archive_after_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM process_summary(NEW.meeting_id);
    PERFORM process_transcript(NEW.meeting_id);
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION archive_after_insert() IS
    'Trigger function: processes a newly inserted archive row into meetings and utterances';

CREATE TRIGGER archive_insert_trigger
    AFTER INSERT ON archive
    FOR EACH ROW
    EXECUTE FUNCTION archive_after_insert();
