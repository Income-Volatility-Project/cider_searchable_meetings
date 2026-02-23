-- Add meeting date and name to search_utterances results via JOIN with meetings.
-- Enables the UI to display meeting date instead of raw meeting_id and to
-- group utterance results by meeting sorted by date.

DROP FUNCTION IF EXISTS search_utterances(TEXT);

CREATE OR REPLACE FUNCTION search_utterances(query TEXT)
RETURNS TABLE (
    id           BIGINT,
    meeting_id   TEXT,
    meeting_name TEXT,
    date         TIMESTAMP WITH TIME ZONE,
    speaker      TEXT,
    text         TEXT,
    start_time   INTEGER,
    end_time     INTEGER,
    rank         REAL
)
LANGUAGE sql
STABLE
AS $$
    SELECT
        u.id,
        u.meeting_id,
        m.meeting_name,
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
    'Full-text search over utterances.text; returns meeting date and name via JOIN for UI grouping';
