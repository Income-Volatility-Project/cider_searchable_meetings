-- Functions to process hex-encoded meeting transcripts into utterances
-- This assumes data is hex-encoded JSON (no compression)

-- Helper function to parse VTT timestamps into milliseconds
CREATE OR REPLACE FUNCTION parse_vtt_timestamp(ts TEXT)
RETURNS INTEGER
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_cleaned TEXT;
    v_parts TEXT[];
    v_hours INTEGER;
    v_minutes INTEGER;
    v_seconds INTEGER;
    v_milliseconds INTEGER;
    v_sec_ms TEXT[];
BEGIN
    v_cleaned := trim(ts);

    -- Split by colons: HH:MM:SS.mmm
    v_parts := string_to_array(v_cleaned, ':');

    IF array_length(v_parts, 1) != 3 THEN
        RAISE EXCEPTION 'Expected HH:MM:SS format, got %', ts;
    END IF;

    v_hours := v_parts[1]::INTEGER;
    v_minutes := v_parts[2]::INTEGER;

    -- Split seconds and milliseconds
    v_sec_ms := string_to_array(v_parts[3], '.');

    IF array_length(v_sec_ms, 1) != 2 THEN
        RAISE EXCEPTION 'Expected seconds.milliseconds format, got %', v_parts[3];
    END IF;

    v_seconds := v_sec_ms[1]::INTEGER;
    v_milliseconds := v_sec_ms[2]::INTEGER;

    -- Validate ranges
    IF v_hours < 0 OR v_hours >= 24 THEN
        RAISE EXCEPTION 'Hours must be 0-23, got %', v_hours;
    END IF;

    IF v_minutes < 0 OR v_minutes >= 60 THEN
        RAISE EXCEPTION 'Minutes must be 0-59, got %', v_minutes;
    END IF;

    IF v_seconds < 0 OR v_seconds >= 60 THEN
        RAISE EXCEPTION 'Seconds must be 0-59, got %', v_seconds;
    END IF;

    -- Return total milliseconds
    RETURN v_hours * 3600000 + v_minutes * 60000 + v_seconds * 1000 + v_milliseconds;
END;
$$;

COMMENT ON FUNCTION parse_vtt_timestamp(TEXT) IS
    'Parse a VTT timestamp (HH:MM:SS.mmm) into milliseconds';


-- Main function to process a single transcript
-- VTT format: blank-line-delimited cue blocks, each containing an optional
-- cue identifier, a "HH:MM:SS.mmm --> HH:MM:SS.mmm" timestamp line, and one
-- or more text lines.  Multi-line cues are joined with a space.
CREATE OR REPLACE FUNCTION process_transcript(p_meeting_id TEXT)
RETURNS TABLE (
    utterances_created INTEGER,
    success BOOLEAN,
    error_message TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_transcript_bytea BYTEA;
    v_transcript_text  TEXT;
    v_transcript_json  JSONB;
    v_vtt_content      TEXT;
    v_blocks           TEXT[];
    v_block            TEXT;
    v_block_lines      TEXT[];
    v_line             TEXT;
    v_timestamp_line   TEXT;
    v_text_lines       TEXT[];
    v_start_time       INTEGER;
    v_end_time         INTEGER;
    v_duration         INTEGER;
    v_speaker          TEXT;
    v_utterance_text   TEXT;
    v_count            INTEGER := 0;
    v_i                INTEGER;
    v_j                INTEGER;
    v_found_ts         BOOLEAN;
BEGIN
    SELECT transcript INTO v_transcript_bytea
    FROM archive
    WHERE meeting_id = p_meeting_id;

    IF NOT FOUND THEN
        RETURN QUERY SELECT 0, false, 'Archive record not found';
        RETURN;
    END IF;

    BEGIN
        v_transcript_text := convert_from(v_transcript_bytea, 'UTF8');
        v_transcript_json := v_transcript_text::jsonb;

        v_vtt_content := v_transcript_json->>'vtt';
        IF v_vtt_content IS NULL THEN
            RETURN QUERY SELECT 0, false, 'No VTT data found in transcript';
            RETURN;
        END IF;

        -- Normalize Windows line endings so blank-line splitting works regardless of source
        v_vtt_content := replace(v_vtt_content, E'\r\n', E'\n');
        v_vtt_content := replace(v_vtt_content, E'\r', E'\n');

        -- Clear existing utterances so the function is idempotent
        DELETE FROM utterances WHERE meeting_id = p_meeting_id;

        -- Split into cue blocks on one or more blank lines
        v_blocks := regexp_split_to_array(v_vtt_content, E'\n[ \t]*\n+');

        FOR v_i IN 1..array_length(v_blocks, 1) LOOP
            v_block := trim(v_blocks[v_i]);

            -- Skip empty blocks, the WEBVTT header, NOTE and STYLE blocks
            CONTINUE WHEN length(v_block) = 0;
            CONTINUE WHEN v_block LIKE 'WEBVTT%';
            CONTINUE WHEN v_block LIKE 'NOTE%';
            CONTINUE WHEN v_block LIKE 'STYLE%';

            v_block_lines  := string_to_array(v_block, E'\n');
            v_timestamp_line := NULL;
            v_text_lines   := ARRAY[]::TEXT[];
            v_found_ts     := false;

            FOR v_j IN 1..array_length(v_block_lines, 1) LOOP
                v_line := trim(v_block_lines[v_j]);
                IF NOT v_found_ts THEN
                    IF position('-->' IN v_line) > 0 THEN
                        v_timestamp_line := v_line;
                        v_found_ts := true;
                    END IF;
                    -- Lines before --> are optional cue identifiers; skip them
                ELSIF length(v_line) > 0 THEN
                    v_text_lines := array_append(v_text_lines, v_line);
                END IF;
            END LOOP;

            -- Skip blocks with no timestamp or no text
            CONTINUE WHEN v_timestamp_line IS NULL;
            CONTINUE WHEN coalesce(array_length(v_text_lines, 1), 0) = 0;

            v_start_time := parse_vtt_timestamp(split_part(v_timestamp_line, '-->', 1));
            v_end_time   := parse_vtt_timestamp(split_part(v_timestamp_line, '-->', 2));
            v_duration   := v_end_time - v_start_time;

            -- First text line carries "Speaker: utterance"; remaining lines are
            -- continuations of the same utterance and are appended with a space.
            IF position(':' IN v_text_lines[1]) = 0 THEN
                RAISE EXCEPTION 'Invalid speaker line: %', v_text_lines[1];
            END IF;

            v_speaker        := trim(split_part(v_text_lines[1], ':', 1));
            v_utterance_text := trim(substring(v_text_lines[1] FROM position(':' IN v_text_lines[1]) + 1));

            FOR v_j IN 2..coalesce(array_length(v_text_lines, 1), 1) LOOP
                v_utterance_text := v_utterance_text || ' ' || trim(v_text_lines[v_j]);
            END LOOP;

            INSERT INTO utterances (meeting_id, start_time, end_time, duration, speaker, text)
            VALUES (p_meeting_id, v_start_time, v_end_time, v_duration, v_speaker, v_utterance_text);

            v_count := v_count + 1;
        END LOOP;

        RETURN QUERY SELECT v_count, true, NULL::TEXT;

    EXCEPTION WHEN OTHERS THEN
        RETURN QUERY SELECT 0, false, SQLERRM;
    END;
END;
$$;

COMMENT ON FUNCTION process_transcript(TEXT) IS
    'Process a meeting transcript (hex-encoded JSON with VTT data) and create utterances';


-- Batch processing function to process all unprocessed transcripts
CREATE OR REPLACE FUNCTION process_all_transcripts()
RETURNS TABLE (
    meeting_id TEXT,
    utterances_created INTEGER,
    success BOOLEAN,
    error_message TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_meeting RECORD;
    v_result RECORD;
BEGIN
    FOR v_meeting IN
        SELECT DISTINCT a.meeting_id
        FROM archive a
        LEFT JOIN utterances u ON a.meeting_id = u.meeting_id
        WHERE u.meeting_id IS NULL
    LOOP
        SELECT * INTO v_result
        FROM process_transcript(v_meeting.meeting_id);

        RETURN QUERY SELECT v_meeting.meeting_id, v_result.utterances_created,
                           v_result.success, v_result.error_message;
    END LOOP;
END;
$$;

COMMENT ON FUNCTION process_all_transcripts() IS
    'Batch process all transcripts that do not have utterances yet';


-- Helper function to insert test data
CREATE OR REPLACE FUNCTION insert_test_archive(
    p_meeting_id TEXT,
    p_vtt_content TEXT,
    p_summary_json JSONB
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_transcript_json JSONB;
    v_transcript_bytea BYTEA;
    v_summary_bytea BYTEA;
BEGIN
    -- Wrap VTT in transcript object
    v_transcript_json := jsonb_build_object('vtt', p_vtt_content);

    -- Convert to bytea
    v_transcript_bytea := convert_to(v_transcript_json::text, 'UTF8');
    v_summary_bytea := convert_to(p_summary_json::text, 'UTF8');

    -- Insert
    INSERT INTO archive (meeting_id, transcript, summary)
    VALUES (p_meeting_id, v_transcript_bytea, v_summary_bytea);

    RAISE NOTICE 'Inserted test archive record for meeting_id: %', p_meeting_id;
END;
$$;

COMMENT ON FUNCTION insert_test_archive(TEXT, TEXT, JSONB) IS
    'Helper function to insert test data into archive table';
