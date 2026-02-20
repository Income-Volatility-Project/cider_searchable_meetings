BEGIN;
SELECT plan(14);

-- ── Schema checks ─────────────────────────────────────────────────────────────

SELECT col_type_is('public', 'utterances', 'text_tsv', 'tsvector',
    'utterances.text_tsv should be tsvector');

SELECT col_type_is('public', 'meetings', 'summary_tsv', 'tsvector',
    'meetings.summary_tsv should be tsvector');

SELECT has_index('public', 'utterances', 'idx_utterances_text_tsv',
    'GIN index on utterances.text_tsv should exist');

SELECT has_index('public', 'meetings', 'idx_meetings_summary_tsv',
    'GIN index on meetings.summary_tsv should exist');

-- ── Fixture data ──────────────────────────────────────────────────────────────

SELECT insert_test_archive(
    'fts_test_basic',
    E'WEBVTT\n\n00:00:01.000 --> 00:00:05.000\nAlice: The quarterly budget review is essential for planning.\n\n00:00:06.000 --> 00:00:10.000\nBob: We need to discuss the marketing expenditure immediately.',
    '{"overallSummary": "Budget and marketing planning session.", "finalSummaryString": "The team reviewed quarterly budget allocations and discussed marketing expenditure cuts.", "topic": "Q3 Budget Review", "startTime": "Jun 15, 2024 10:00 AM Eastern Daylight Time"}'::jsonb
);

-- Meeting with NULL summaries to test COALESCE handling
INSERT INTO archive (meeting_id, summary, transcript)
VALUES (
    'fts_test_null_summary',
    convert_to('{"overallSummary": null, "finalSummaryString": null, "topic": "Null Summary Meeting", "startTime": "Jun 15, 2024 10:00 AM Eastern Daylight Time"}'::text, 'UTF8'),
    convert_to('{"vtt": "WEBVTT\n\n00:00:01.000 --> 00:00:05.000\nHost: This is a filler utterance."}'::text, 'UTF8')
);

-- ── tsvector population ───────────────────────────────────────────────────────

-- utterances.text_tsv should contain stemmed tokens from the text column
SELECT ok(
    (SELECT text_tsv @@ to_tsquery('english', 'budget') FROM utterances WHERE meeting_id = 'fts_test_basic' AND speaker = 'Alice'),
    'utterances.text_tsv for Alice should match query for "budget"'
);

-- meetings.summary_tsv should combine both short_summary and full_summary
SELECT ok(
    (SELECT summary_tsv @@ to_tsquery('english', 'allocation') FROM meetings WHERE meeting_id = 'fts_test_basic'),
    'meetings.summary_tsv should match token from full_summary ("allocation")'
);

SELECT ok(
    (SELECT summary_tsv @@ to_tsquery('english', 'marketing') FROM meetings WHERE meeting_id = 'fts_test_basic'),
    'meetings.summary_tsv should match token from short_summary ("marketing")'
);

-- NULL summaries should not break the generated column (COALESCE → empty string)
SELECT ok(
    (SELECT summary_tsv IS NOT NULL FROM meetings WHERE meeting_id = 'fts_test_null_summary'),
    'meetings.summary_tsv should not be NULL when summaries are NULL'
);

-- ── search_utterances() ───────────────────────────────────────────────────────

SELECT ok(
    EXISTS (SELECT 1 FROM search_utterances('budget planning') WHERE meeting_id = 'fts_test_basic'),
    'search_utterances should return results for "budget planning"'
);

-- Should return no results for a term that does not appear
SELECT is(
    (SELECT count(*)::int FROM search_utterances('xyzzy_nonexistent_term')),
    0,
    'search_utterances should return 0 rows for unmatched query'
);

-- rank should be positive for a match
SELECT ok(
    (SELECT rank > 0 FROM search_utterances('budget planning') WHERE meeting_id = 'fts_test_basic' LIMIT 1),
    'search_utterances rank should be positive for a match'
);

-- ── search_meetings() ─────────────────────────────────────────────────────────

SELECT ok(
    EXISTS (SELECT 1 FROM search_meetings('marketing expenditure') WHERE meeting_id = 'fts_test_basic'),
    'search_meetings should return results for "marketing expenditure"'
);

-- Should return no results for a term that does not appear
SELECT is(
    (SELECT count(*)::int FROM search_meetings('xyzzy_nonexistent_term')),
    0,
    'search_meetings should return 0 rows for unmatched query'
);

-- NULL-summary meeting should not appear in search results (nothing to match)
SELECT is(
    (SELECT count(*)::int FROM search_meetings('filler') WHERE meeting_id = 'fts_test_null_summary'),
    0,
    'meeting with NULL summaries should not appear in search_meetings results'
);

SELECT * FROM finish();
ROLLBACK;
