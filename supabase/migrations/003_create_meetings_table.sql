-- Create meetings table and functions to populate it from archive summaries
-- Mirrors the logic in old/database.py (add_meeting_info_to_db) and
-- old/summary_handler.py (parse_summary_object)

CREATE TABLE IF NOT EXISTS meetings (
    meeting_id TEXT PRIMARY KEY,
    short_summary TEXT,
    full_summary TEXT,
    meeting_name TEXT,
    date TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),

    FOREIGN KEY (meeting_id) REFERENCES archive (meeting_id) ON DELETE CASCADE
);

CREATE INDEX idx_meetings_date ON meetings(date);

COMMENT ON TABLE meetings IS 'Parsed meeting metadata extracted from archive summaries';
COMMENT ON COLUMN meetings.date IS 'Meeting start time (parsed from summary startTime, stamped as America/New_York)';

-- RLS: public SELECT; writes require service_role key
ALTER TABLE meetings ENABLE ROW LEVEL SECURITY;

CREATE POLICY "meetings_select_public"
    ON meetings
    FOR SELECT
    TO anon, authenticated
    USING (true);


-- Parse a single archive summary and upsert into the meetings table.
-- Mirrors parse_summary_object() + add_meeting_info_to_db() in old/database.py.
--
-- The summary BYTEA is UTF-8–encoded JSON with fields:
--   overallSummary, finalSummaryString, topic, startTime
--
-- startTime may contain a trailing parenthetical like " (Eastern Daylight Time)"
-- which is stripped before parsing, replicating the Python re.sub behaviour.
-- The resulting naive timestamp is then stamped as America/New_York, matching
-- Python's date.replace(tzinfo=ZoneInfo("America/New_York")).
CREATE OR REPLACE FUNCTION process_summary(p_meeting_id TEXT)
RETURNS TABLE (
    success       BOOLEAN,
    error_message TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_summary_bytea BYTEA;
    v_summary_json  JSONB;
    v_short_summary TEXT;
    v_full_summary  TEXT;
    v_meeting_name  TEXT;
    v_date_str      TEXT;
    v_date          TIMESTAMP WITH TIME ZONE;
BEGIN
    SELECT summary INTO v_summary_bytea
    FROM archive
    WHERE meeting_id = p_meeting_id;

    IF NOT FOUND THEN
        RETURN QUERY SELECT false, 'Archive record not found';
        RETURN;
    END IF;

    BEGIN
        v_summary_json  := convert_from(v_summary_bytea, 'UTF8')::jsonb;

        v_short_summary := v_summary_json->>'overallSummary';
        v_full_summary  := v_summary_json->>'finalSummaryString';
        v_meeting_name  := v_summary_json->>'topic';

        -- Strip everything after AM/PM (handles " Eastern Time", " (Eastern Daylight Time)", " EDT", etc.)
        v_date_str := regexp_replace(v_summary_json->>'startTime', '^(.*?\m(?:AM|PM))\M.*$', '\1', 'i');
        v_date     := to_timestamp(trim(v_date_str), 'Mon DD, YYYY HH:MI AM') AT TIME ZONE 'America/New_York';

        INSERT INTO meetings (meeting_id, short_summary, full_summary, meeting_name, date)
        VALUES (p_meeting_id, v_short_summary, v_full_summary, v_meeting_name, v_date)
        ON CONFLICT (meeting_id) DO UPDATE SET
            short_summary = EXCLUDED.short_summary,
            full_summary  = EXCLUDED.full_summary,
            meeting_name  = EXCLUDED.meeting_name,
            date          = EXCLUDED.date;

        RETURN QUERY SELECT true, NULL::TEXT;

    EXCEPTION WHEN OTHERS THEN
        RETURN QUERY SELECT false, SQLERRM;
    END;
END;
$$;

COMMENT ON FUNCTION process_summary(TEXT) IS
    'Parse a meeting summary from archive and upsert into meetings table';


-- Batch-process all archive records that do not yet have a meetings row.
-- Mirrors the bootstrap logic in old/database.py add_meeting_info_to_db().
CREATE OR REPLACE FUNCTION process_all_summaries()
RETURNS TABLE (
    meeting_id    TEXT,
    success       BOOLEAN,
    error_message TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_meeting RECORD;
    v_result  RECORD;
BEGIN
    FOR v_meeting IN
        SELECT DISTINCT a.meeting_id
        FROM archive a
        LEFT JOIN meetings m ON a.meeting_id = m.meeting_id
        WHERE m.meeting_id IS NULL
    LOOP
        SELECT * INTO v_result
        FROM process_summary(v_meeting.meeting_id);

        RETURN QUERY SELECT v_meeting.meeting_id, v_result.success, v_result.error_message;
    END LOOP;
END;
$$;

COMMENT ON FUNCTION process_all_summaries() IS
    'Batch process all archive records that do not have a meetings entry yet';
