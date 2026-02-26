CREATE OR REPLACE FUNCTION openai_embed(p_text TEXT)
RETURNS vector(1536)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, vault
AS $$
DECLARE
    v_api_key  TEXT;
    v_response http_response;
BEGIN
    SELECT decrypted_secret INTO v_api_key
    FROM vault.decrypted_secrets
    WHERE name = 'OPENAI_API_KEY';

    IF v_api_key IS NULL THEN
        RAISE EXCEPTION 'OPENAI_API_KEY not found in vault. '
            'Run: SELECT vault.create_secret(''sk-…'', ''OPENAI_API_KEY'');';
    END IF;

    PERFORM http_set_curlopt('CURLOPT_TIMEOUT_MS', '30000');

    SELECT * INTO v_response
    FROM http((
        'POST',
        'https://api.openai.com/v1/embeddings',
        ARRAY[
            http_header('Authorization', 'Bearer ' || v_api_key)
        ],
        'application/json',
        jsonb_build_object(
            'model', 'text-embedding-3-small',
            'input', p_text
        )::text
    )::http_request);

    IF v_response.status <> 200 THEN
        RAISE EXCEPTION 'OpenAI API error (HTTP %): %',
            v_response.status, v_response.content;
    END IF;

    RETURN (v_response.content::jsonb -> 'data' -> 0 -> 'embedding')
               ::text::vector(1536);
END;
$$;

COMMENT ON FUNCTION openai_embed(TEXT) IS
    'Synchronously call OpenAI text-embedding-3-small via pgsql-http and return '
    'a vector(1536).  Reads API key from vault secret named OPENAI_API_KEY. '
    'HTTP timeout is 2 minutes.';



CREATE OR REPLACE FUNCTION embed_1_meeting()
RETURNS TABLE (
    meeting_id          TEXT,
    utterances_embedded INTEGER,
    meeting_success     BOOLEAN,
    utterances_success  BOOLEAN,
    error_message       TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_meeting    RECORD;
    v_meet_res   RECORD;
    v_utt_res    RECORD;
BEGIN
    FOR v_meeting IN
        SELECT m.meeting_id
        FROM   meetings m
        WHERE  m.short_summary_embedding IS NULL
          AND  m.short_summary IS NOT NULL
          AND  length(trim(m.short_summary)) > 0
        ORDER  BY m.meeting_id
        LIMIT 1 
        FOR UPDATE SKIP LOCKED
    LOOP
        SELECT * INTO v_meet_res FROM embed_meeting(v_meeting.meeting_id);
        SELECT * INTO v_utt_res  FROM embed_utterances(v_meeting.meeting_id);

        RETURN QUERY SELECT
            v_meeting.meeting_id,
            v_utt_res.utterances_embedded,
            v_meet_res.success,
            v_utt_res.success,
            COALESCE(v_meet_res.error_message, v_utt_res.error_message);
    END LOOP;
END;
$$;

SELECT cron.unschedule('embed-pending')
FROM   cron.job
WHERE  jobname = 'embed-pending';

SELECT cron.schedule('embed-pending', '*/1 * * * *', 'SELECT embed_1_meeting()');
