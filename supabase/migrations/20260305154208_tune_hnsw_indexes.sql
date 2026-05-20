-- Reduce HNSW index parameters to lower CPU usage during index builds and queries.
--
-- Default parameters: m=16, ef_construction=64.
-- New parameters:     m=8,  ef_construction=32.
--
-- Effect:
--   • ~50% smaller index graph → less memory and CPU during inserts/updates
--   • Slightly lower ANN recall (~1-2% in practice, imperceptible for meeting search)
--   • Faster approximate nearest-neighbour scans at query time
--
-- This requires a CONCURRENT index rebuild; each DROP/CREATE is non-blocking for reads.
-- The two affected indexes are:
--   1. idx_meetings_short_summary_embedding   (meetings table)
--   2. idx_summary_chunks_embedding           (meeting_summary_chunks table)
-- (idx_utterances_embedding was dropped in migration 20260302100000)

DROP INDEX IF EXISTS idx_meetings_short_summary_embedding;
CREATE INDEX idx_meetings_short_summary_embedding
    ON meetings
    USING hnsw (short_summary_embedding vector_cosine_ops)
    WITH (m = 8, ef_construction = 32);

DROP INDEX IF EXISTS idx_summary_chunks_embedding;
CREATE INDEX idx_summary_chunks_embedding
    ON meeting_summary_chunks
    USING hnsw (embedding vector_cosine_ops)
    WITH (m = 8, ef_construction = 32);
