-- Migration: make embed_utterances() resumable
--
-- Previously, embed_utterances() re-embedded ALL utterances for a meeting on
-- every call, so a timeout mid-meeting meant the next call would start over
-- from scratch. Adding `AND embedding IS NULL` makes it skip already-embedded
-- rows, so retries only process the remaining utterances.

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
    'have an embedding. Resumable: safe to call multiple times.';
