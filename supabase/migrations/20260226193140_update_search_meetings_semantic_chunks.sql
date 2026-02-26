-- Update search_meetings_semantic to rank meetings by:
--   best chunk similarity (1 per meeting)  +  0.25 × short_summary similarity
--
-- The return signature is unchanged so the UI requires no modifications.

CREATE OR REPLACE FUNCTION search_meetings_semantic(
    query       TEXT,
    match_count INTEGER DEFAULT 10
)
RETURNS TABLE (
    meeting_id    TEXT,
    meeting_name  TEXT,
    short_summary TEXT,
    date          TIMESTAMP WITH TIME ZONE,
    similarity    REAL
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_query_embedding vector(1536);
BEGIN
    v_query_embedding := openai_embed(query);

    RETURN QUERY
    WITH best_chunk_per_meeting AS (
        -- For each meeting, keep only the single highest-similarity chunk.
        SELECT
            c.meeting_id,
            MAX(1 - (c.embedding <=> v_query_embedding)) AS chunk_similarity
        FROM   meeting_summary_chunks c
        WHERE  c.embedding IS NOT NULL
        GROUP  BY c.meeting_id
    )
    SELECT
        m.meeting_id,
        m.meeting_name,
        m.short_summary,
        m.date,
        -- Combined score: best chunk + 1/4 of short-summary signal.
        -- COALESCE guards against meetings whose short_summary_embedding is
        -- not yet populated; those still appear ranked on chunk score alone.
        (bc.chunk_similarity
            + 0.25 * COALESCE(1 - (m.short_summary_embedding <=> v_query_embedding), 0.0)
        )::REAL AS similarity
    FROM   meetings m
    JOIN   best_chunk_per_meeting bc USING (meeting_id)
    ORDER  BY similarity DESC
    LIMIT  match_count;
END;
$$;

COMMENT ON FUNCTION search_meetings_semantic(TEXT, INTEGER) IS
    'Semantic search over meetings. Scores each meeting as: '
    '(best chunk cosine-similarity) + 0.25 * (short_summary cosine-similarity). '
    'Returns top match_count meetings ordered by that combined score, descending.';
