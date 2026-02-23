-- Full-text search for utterances.text and meetings.short_summary / full_summary
--
-- Strategy: generated STORED tsvector columns + GIN indexes.
-- No triggers needed — Postgres keeps generated columns in sync automatically.
-- websearch_to_tsquery() is used in the search helpers so callers can pass
-- natural-language queries (e.g. "budget planning" or "budget OR planning").

-- ── utterances ──────────────────────────────────────────────────────────────

ALTER TABLE utterances
    ADD COLUMN text_tsv tsvector
        GENERATED ALWAYS AS (to_tsvector('english', text)) STORED;

CREATE INDEX idx_utterances_text_tsv ON utterances USING GIN (text_tsv);

COMMENT ON COLUMN utterances.text_tsv IS
    'Generated tsvector for full-text search on utterances.text';


-- ── meetings ─────────────────────────────────────────────────────────────────

ALTER TABLE meetings
    ADD COLUMN summary_tsv tsvector
        GENERATED ALWAYS AS (
            to_tsvector(
                'english',
                coalesce(short_summary, '') || ' ' || coalesce(full_summary, '')
            )
        ) STORED;

CREATE INDEX idx_meetings_summary_tsv ON meetings USING GIN (summary_tsv);

COMMENT ON COLUMN meetings.summary_tsv IS
    'Generated tsvector for full-text search across short_summary and full_summary';


-- ── search helpers ───────────────────────────────────────────────────────────

-- Returns matching utterances ranked by relevance, with meeting metadata via JOIN.
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


-- Returns matching meetings ranked by relevance.
CREATE OR REPLACE FUNCTION search_meetings(query TEXT)
RETURNS TABLE (
    meeting_id    TEXT,
    meeting_name  TEXT,
    short_summary TEXT,
    full_summary  TEXT,
    date          TIMESTAMP WITH TIME ZONE,
    rank          REAL
)
LANGUAGE sql
STABLE
AS $$
    SELECT
        meeting_id,
        meeting_name,
        short_summary,
        full_summary,
        date,
        ts_rank(summary_tsv, websearch_to_tsquery('english', query))::REAL AS rank
    FROM meetings
    WHERE summary_tsv @@ websearch_to_tsquery('english', query)
    ORDER BY rank DESC;
$$;

COMMENT ON FUNCTION search_meetings(TEXT) IS
    'Full-text search over meetings.short_summary and full_summary; accepts websearch-style queries';
