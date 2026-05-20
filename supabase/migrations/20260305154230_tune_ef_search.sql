-- Apply SET LOCAL hnsw.ef_search = 20 to search_meeting_chunks_semantic.
--
-- ef_search controls the size of the dynamic candidate list during HNSW graph
-- traversal at query time.  The default is 40.  Halving it to 20 roughly halves
-- CPU work per vector scan, with negligible recall loss for this use case.
--
-- search_meetings_semantic already sets this in migration 20260305154113.
-- This migration covers the remaining vector search function.

CREATE OR REPLACE FUNCTION search_meeting_chunks_semantic(
    query       TEXT,
    match_count INTEGER DEFAULT 10
)
RETURNS TABLE (
    chunk_id     BIGINT,
    meeting_id   TEXT,
    meeting_name TEXT,
    chunk_index  INTEGER,
    chunk_text   TEXT,
    similarity   REAL
)
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $$
DECLARE
    v_query_embedding vector(1536);
BEGIN
    v_query_embedding := openai_embed(query);

    SET LOCAL hnsw.ef_search = 20;

    RETURN QUERY
    SELECT
        c.id,
        c.meeting_id,
        m.meeting_name,
        c.chunk_index,
        c.chunk_text,
        (1 - (c.embedding <=> v_query_embedding))::REAL AS similarity
    FROM   meeting_summary_chunks c
    JOIN   meetings m USING (meeting_id)
    WHERE  c.embedding IS NOT NULL
    ORDER  BY c.embedding <=> v_query_embedding
    LIMIT  match_count;
END;
$$;

COMMENT ON FUNCTION search_meeting_chunks_semantic(TEXT, INTEGER) IS
    'Semantic search over full_summary paragraphs. Returns top match_count chunks '
    'by cosine similarity, descending, with their parent meeting_name. '
    'Uses hnsw.ef_search=20 to reduce CPU at query time.';
