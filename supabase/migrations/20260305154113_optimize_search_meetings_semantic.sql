-- Optimize search_meetings_semantic to use the HNSW index on meeting_summary_chunks.
--
-- Problem: the previous implementation did:
--   SELECT meeting_id, MAX(1 - (embedding <=> q)) ... GROUP BY meeting_id
-- PostgreSQL cannot use the HNSW ANN index for GROUP BY + MAX aggregation, so
-- it fell back to a full sequential scan computing cosine distance for every chunk.
-- As meetings accumulate this is O(N) CPU work on every user search query.
--
-- Fix: pre-filter to the top (match_count * 5) chunks using ORDER BY...LIMIT,
-- which the planner *can* satisfy with the HNSW index.  Then aggregate over
-- that small result set.  Oversampling by 5x ensures we always see the best
-- chunk for each of the top match_count meetings even when chunks are unevenly
-- distributed across meetings.

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
SET search_path = public
AS $$
DECLARE
    v_query_embedding vector(1536);
    v_oversample      INTEGER;
BEGIN
    v_query_embedding := openai_embed(query);
    -- Oversample: fetch at least 50 chunks, or 5x the requested meeting count.
    v_oversample := GREATEST(match_count * 5, 50);

    -- Lower ef_search for this query: trades a tiny bit of recall for CPU savings.
    -- Default is 40; 20 is sufficient for meeting-level granularity.
    SET LOCAL hnsw.ef_search = 20;

    RETURN QUERY
    WITH top_chunks AS (
        -- HNSW index is usable here because of ORDER BY + LIMIT (no aggregation).
        SELECT
            c.meeting_id,
            1 - (c.embedding <=> v_query_embedding) AS chunk_similarity
        FROM   meeting_summary_chunks c
        WHERE  c.embedding IS NOT NULL
        ORDER  BY c.embedding <=> v_query_embedding
        LIMIT  v_oversample
    ),
    best_chunk_per_meeting AS (
        -- Aggregate over the small pre-filtered set, not the whole table.
        SELECT
            tc.meeting_id,
            MAX(tc.chunk_similarity) AS chunk_similarity
        FROM   top_chunks tc
        GROUP  BY tc.meeting_id
    )
    SELECT
        m.meeting_id,
        m.meeting_name,
        m.short_summary,
        m.date,
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
    'Semantic search over meetings. '
    'Pre-filters top GREATEST(match_count*5, 50) chunks via HNSW ANN index '
    '(ORDER BY...LIMIT), then aggregates to 1 row per meeting. '
    'Score = best_chunk_similarity + 0.25 * short_summary_similarity. '
    'Returns top match_count meetings ordered by that combined score, descending.';
