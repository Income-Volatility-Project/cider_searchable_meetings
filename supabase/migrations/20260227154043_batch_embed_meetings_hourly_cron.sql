-- Replace embed_1_short_summary with a batch version that embeds multiple
-- meetings (short_summary + full_summary chunks) in a single OpenAI API call,
-- and reduce both cron jobs from every minute to every hour.

-- ── embed_1_meeting_batch ─────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS embed_1_short_summary();

CREATE OR REPLACE FUNCTION embed_1_meeting_batch(p_batch_size INTEGER DEFAULT 32)
RETURNS TABLE (meetings_embedded INTEGER, success BOOLEAN, error_message TEXT)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
    v_texts       TEXT[]    := ARRAY[]::TEXT[];
    v_meeting_ids TEXT[]    := ARRAY[]::TEXT[];
    v_is_short    BOOLEAN[] := ARRAY[]::BOOLEAN[];
    v_chunk_idxs  INTEGER[] := ARRAY[]::INTEGER[];
    v_embeddings  vector(1536)[];
    v_count       INTEGER := 0;
    v_pos         INTEGER := 0;
    v_i           INTEGER;
    v_meeting     RECORD;
    v_chunk       RECORD;
BEGIN
    BEGIN
        FOR v_meeting IN
            SELECT m.meeting_id, m.short_summary, m.full_summary
            FROM   meetings m
            WHERE  m.short_summary_embedding IS NULL
              AND  m.short_summary IS NOT NULL
              AND  length(trim(m.short_summary)) > 0
            ORDER  BY m.meeting_id
            LIMIT  p_batch_size
            FOR UPDATE SKIP LOCKED
        LOOP
            -- Short summary slot
            v_pos         := v_pos + 1;
            v_texts       := array_append(v_texts,       v_meeting.short_summary);
            v_meeting_ids := array_append(v_meeting_ids, v_meeting.meeting_id);
            v_is_short    := array_append(v_is_short,    TRUE);
            v_chunk_idxs  := array_append(v_chunk_idxs,  NULL::INTEGER);

            -- Rebuild full_summary chunks: delete old rows now, insert after embedding
            DELETE FROM meeting_summary_chunks WHERE meeting_id = v_meeting.meeting_id;

            IF v_meeting.full_summary IS NOT NULL
                    AND length(trim(v_meeting.full_summary)) > 0 THEN
                FOR v_chunk IN
                    SELECT * FROM chunk_full_summary(v_meeting.full_summary)
                LOOP
                    v_pos         := v_pos + 1;
                    v_texts       := array_append(v_texts,       v_chunk.chunk_text);
                    v_meeting_ids := array_append(v_meeting_ids, v_meeting.meeting_id);
                    v_is_short    := array_append(v_is_short,    FALSE);
                    v_chunk_idxs  := array_append(v_chunk_idxs,  v_chunk.chunk_index);
                END LOOP;
            END IF;

            v_count := v_count + 1;
        END LOOP;

        IF v_pos = 0 THEN
            RETURN QUERY SELECT 0, TRUE, NULL::TEXT;
            RETURN;
        END IF;

        v_embeddings := openai_embed_batch(v_texts);

        FOR v_i IN 1 .. v_pos LOOP
            IF v_is_short[v_i] THEN
                UPDATE meetings
                SET    short_summary_embedding = v_embeddings[v_i]
                WHERE  meeting_id = v_meeting_ids[v_i];
            ELSE
                INSERT INTO meeting_summary_chunks
                           (meeting_id, chunk_index, chunk_text, embedding)
                VALUES     (v_meeting_ids[v_i],
                            v_chunk_idxs[v_i],
                            v_texts[v_i],
                            v_embeddings[v_i]);
            END IF;
        END LOOP;

        RETURN QUERY SELECT v_count, TRUE, NULL::TEXT;

    EXCEPTION WHEN OTHERS THEN
        RETURN QUERY SELECT v_count, FALSE, SQLERRM;
    END;
END;
$$;

-- ── Update cron schedules to hourly ──────────────────────────────────────────

-- Meeting summaries: switch to batch function, run once per hour
SELECT cron.schedule(
    'embed-short-summaries', '0 * * * *',
    'SELECT embed_1_meeting_batch()'
);

-- Utterance batches: same function, run once per hour
SELECT cron.schedule(
    'embed-utterance-batches', '0 * * * *',
    'SELECT embed_1_utterance_batch()'
);
