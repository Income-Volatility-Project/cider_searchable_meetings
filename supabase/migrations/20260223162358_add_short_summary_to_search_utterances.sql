-- Add short_summary to search_utterances so the UI can display it in each
-- meeting group header without a separate query.

DROP FUNCTION IF EXISTS search_utterances(TEXT);

CREATE FUNCTION search_utterances(query TEXT)
RETURNS TABLE (
    id            BIGINT,
    meeting_id    TEXT,
    meeting_name  TEXT,
    short_summary TEXT,
    date          TIMESTAMP WITH TIME ZONE,
    speaker       TEXT,
    text          TEXT,
    start_time    INTEGER,
    end_time      INTEGER,
    rank          REAL
)
LANGUAGE sql
STABLE
AS $$
    SELECT
        u.id,
        u.meeting_id,
        m.meeting_name,
        m.short_summary,
        m.date,
        u.speaker,
        u.text,
        u.start_time,
        u.end_time,
        ts_rank(u.text_tsv, websearch_to_tsquery('english', query))::REAL AS rank
    FROM utterances u
    JOIN meetings m USING (meeting_id)
    WHERE u.text_tsv @@ websearch_to_tsquery('english', query)
    ORDER BY rank DESC;
$$;

COMMENT ON FUNCTION search_utterances(TEXT) IS
    'Full-text search over utterances.text; returns meeting name, short_summary, and date via JOIN for UI grouping';
