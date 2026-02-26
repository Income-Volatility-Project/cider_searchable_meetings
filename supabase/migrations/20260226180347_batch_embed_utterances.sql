-- Batch embedding: send up to 1024 texts in a single OpenAI API call
CREATE OR REPLACE FUNCTION openai_embed_batch(p_texts TEXT[])
RETURNS vector(1536)[]
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, vault
AS $$
DECLARE
    v_api_key  TEXT;
    v_response http_response;
    v_data     JSONB;
    v_results  vector(1536)[];
    v_item     JSONB;
    v_idx      INTEGER;
BEGIN
    IF p_texts IS NULL OR array_length(p_texts, 1) IS NULL THEN
        RETURN ARRAY[]::vector(1536)[];
    END IF;

    SELECT decrypted_secret INTO v_api_key FROM vault.decrypted_secrets
    WHERE name = 'OPENAI_API_KEY';
    IF v_api_key IS NULL THEN
        RAISE EXCEPTION 'OPENAI_API_KEY not found in vault.';
    END IF;

    PERFORM http_set_curlopt('CURLOPT_TIMEOUT_MS', '30000');

    SELECT * INTO v_response FROM http((
        'POST', 'https://api.openai.com/v1/embeddings',
        ARRAY[http_header('Authorization', 'Bearer ' || v_api_key)],
        'application/json',
        jsonb_build_object(
            'model', 'text-embedding-3-small',
            'input', to_jsonb(p_texts)
        )::text
    )::http_request);

    IF v_response.status <> 200 THEN
        RAISE EXCEPTION 'OpenAI API error (HTTP %): %', v_response.status, v_response.content;
    END IF;

    v_data    := v_response.content::jsonb -> 'data';
    v_results := array_fill(NULL::vector(1536), ARRAY[array_length(p_texts, 1)]);

    FOR v_item IN
        SELECT value FROM jsonb_array_elements(v_data)
        ORDER BY (value->>'index')::INTEGER
    LOOP
        v_idx            := (v_item->>'index')::INTEGER + 1;
        v_results[v_idx] := (v_item->'embedding')::text::vector(1536);
    END LOOP;

    RETURN v_results;
END;
$$;

-- Cron target: embed one meeting's short summary per run
CREATE OR REPLACE FUNCTION embed_1_short_summary()
RETURNS TABLE (meeting_id TEXT, success BOOLEAN, error_message TEXT)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
    v_meeting RECORD;
    v_result  RECORD;
BEGIN
    FOR v_meeting IN
        SELECT m.meeting_id
        FROM   meetings m
        WHERE  m.short_summary_embedding IS NULL
          AND  m.short_summary IS NOT NULL
          AND  length(trim(m.short_summary)) > 0
        ORDER  BY m.meeting_id
        LIMIT  1
        FOR UPDATE SKIP LOCKED
    LOOP
        SELECT * INTO v_result FROM embed_meeting(v_meeting.meeting_id);
        RETURN QUERY SELECT v_meeting.meeting_id, v_result.success, v_result.error_message;
    END LOOP;
END;
$$;

-- Cron target: embed up to 1024 utterances system-wide per run
CREATE OR REPLACE FUNCTION embed_1_utterance_batch()
RETURNS TABLE (utterances_embedded INTEGER, success BOOLEAN, error_message TEXT)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
    v_batch_size CONSTANT INTEGER := 1024;
    v_ids        BIGINT[];
    v_texts      TEXT[];
    v_embeddings vector(1536)[];
    v_i          INTEGER;
    v_count      INTEGER := 0;
BEGIN
    BEGIN
        SELECT array_agg(id ORDER BY id), array_agg(text ORDER BY id)
        INTO   v_ids, v_texts
        FROM (
            SELECT id, text
            FROM   utterances
            WHERE  embedding IS NULL
            ORDER  BY id
            LIMIT  v_batch_size
            FOR UPDATE SKIP LOCKED
        ) sub;

        IF v_ids IS NULL THEN
            RETURN QUERY SELECT 0, true, NULL::TEXT;
            RETURN;
        END IF;

        v_embeddings := openai_embed_batch(v_texts);

        FOR v_i IN 1 .. array_length(v_ids, 1) LOOP
            UPDATE utterances
            SET    embedding = v_embeddings[v_i]
            WHERE  id = v_ids[v_i];
        END LOOP;

        v_count := array_length(v_ids, 1);
        RETURN QUERY SELECT v_count, true, NULL::TEXT;

    EXCEPTION WHEN OTHERS THEN
        RETURN QUERY SELECT v_count, false, SQLERRM;
    END;
END;
$$;

-- Replace old single-meeting cron with two independent jobs
SELECT cron.unschedule(jobid)
FROM   cron.job
WHERE  jobname = 'embed-pending';

-- One meeting summary every minute
SELECT cron.schedule(
    'embed-short-summaries', '* * * * *',
    'SELECT embed_1_short_summary()'
);

-- 1024-utterance batch every minute
SELECT cron.schedule(
    'embed-utterance-batches', '* * * * *',
    'SELECT embed_1_utterance_batch()'
);
