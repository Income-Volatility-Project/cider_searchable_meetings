BEGIN;

SELECT plan(1);

-- idx_utterances_unembedded and idx_meeting_summary_chunks_unembedded were
-- dropped in migration 20260302100000_drop_utterance_embeddings.sql (CASCADE
-- with utterances.embedding and explicit DROP respectively).

SELECT has_index(
    'public', 'meetings',
    'idx_meetings_unembedded',
    'partial index exists on meetings(meeting_id) WHERE short_summary_embedding IS NULL'
);

SELECT * FROM finish();

ROLLBACK;
