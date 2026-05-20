-- Drop utterance embedding pipeline and the meeting_summary_chunks partial index.
-- The utterances embedding column, HNSW index, partial index, cron job, and
-- related functions are all removed.  openai_embed_batch / embed_1_short_summary
-- and the meetings / chunk search infrastructure are intentionally preserved.

-- 1. Drop the meeting_summary_chunks partial index (chunk rows are rebuilt atomically)
DROP INDEX IF EXISTS idx_meeting_summary_chunks_unembedded;

-- 2. Remove the utterance-batch cron job
SELECT cron.unschedule('embed-utterance-batches')
FROM   cron.job
WHERE  jobname = 'embed-utterance-batches';

-- 3. Drop utterance-embedding functions
DROP FUNCTION IF EXISTS search_utterances_semantic(TEXT, INTEGER);
DROP FUNCTION IF EXISTS embed_1_utterance_batch();
DROP FUNCTION IF EXISTS embed_utterances(TEXT);
DROP FUNCTION IF EXISTS embed_all_utterances();

-- 4. Drop utterances.embedding column (CASCADE removes idx_utterances_embedding HNSW
--    index and idx_utterances_unembedded partial index automatically)
ALTER TABLE utterances DROP COLUMN IF EXISTS embedding CASCADE;
