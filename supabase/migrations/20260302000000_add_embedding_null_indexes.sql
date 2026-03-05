-- Partial indexes for "find unembedded rows" scans.
--
-- The cron functions open with a table scan filtered by IS NULL on an embedding
-- column. Partial indexes make those scans O(unembedded rows) instead of
-- O(all rows), shrinking automatically as rows get embedded.
--
-- utterances: embed_1_utterance_batch filters WHERE embedding IS NULL ORDER BY id
CREATE INDEX idx_utterances_unembedded
    ON utterances (id)
    WHERE embedding IS NULL;

-- meetings: embed_1_meeting_batch filters
--   WHERE short_summary_embedding IS NULL AND short_summary IS NOT NULL
CREATE INDEX idx_meetings_unembedded
    ON meetings (meeting_id)
    WHERE short_summary_embedding IS NULL
      AND short_summary IS NOT NULL;

-- meeting_summary_chunks: no cron scans for NULL embeddings here (chunks are
-- always deleted and rebuilt atomically), but a partial index guards against
-- any future path that might insert chunks without embeddings.
CREATE INDEX idx_meeting_summary_chunks_unembedded
    ON meeting_summary_chunks (id)
    WHERE embedding IS NULL;
