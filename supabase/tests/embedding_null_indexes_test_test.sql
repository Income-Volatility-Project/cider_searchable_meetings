BEGIN;

SELECT plan(3);

SELECT has_index(
    'public', 'utterances',
    'idx_utterances_unembedded',
    'partial index exists on utterances(id) WHERE embedding IS NULL'
);

SELECT has_index(
    'public', 'meetings',
    'idx_meetings_unembedded',
    'partial index exists on meetings(meeting_id) WHERE short_summary_embedding IS NULL'
);

SELECT has_index(
    'public', 'meeting_summary_chunks',
    'idx_meeting_summary_chunks_unembedded',
    'partial index exists on meeting_summary_chunks(id) WHERE embedding IS NULL'
);

SELECT * FROM finish();

ROLLBACK;
