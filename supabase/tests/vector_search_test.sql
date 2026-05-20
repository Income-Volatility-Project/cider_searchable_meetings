-- pgTAP tests for vector search migration.
--
-- API calls to OpenAI are avoided: tests that exercise search functions
-- insert pre-computed dummy embeddings directly so we can validate schema,
-- chunk splitting, and ANN search logic without network dependencies.
--
-- Note: utterances.embedding and its associated index were removed in
-- migration 20260302100000_drop_utterance_embeddings.sql.

BEGIN;
SELECT plan(13);

-- ── Schema: columns ──────────────────────────────────────────────────────────

SELECT col_type_is('public', 'meetings', 'short_summary_embedding', 'vector(1536)',
    'meetings.short_summary_embedding should be vector(1536)');

-- ── Schema: meeting_summary_chunks table ─────────────────────────────────────

SELECT has_table('public', 'meeting_summary_chunks',
    'meeting_summary_chunks table should exist');

SELECT col_type_is('public', 'meeting_summary_chunks', 'embedding', 'vector(1536)',
    'meeting_summary_chunks.embedding should be vector(1536)');

SELECT col_type_is('public', 'meeting_summary_chunks', 'chunk_index', 'integer',
    'meeting_summary_chunks.chunk_index should be integer');

-- ── Schema: HNSW indexes ─────────────────────────────────────────────────────

SELECT has_index('public', 'meetings', 'idx_meetings_short_summary_embedding',
    'HNSW index on meetings.short_summary_embedding should exist');

SELECT has_index('public', 'meeting_summary_chunks', 'idx_summary_chunks_embedding',
    'HNSW index on meeting_summary_chunks.embedding should exist');

-- ── chunk_full_summary ────────────────────────────────────────────────────────

SELECT results_eq(
    $$SELECT chunk_index, chunk_text
        FROM chunk_full_summary(E'First paragraph.\n\nSecond paragraph.')
        ORDER BY chunk_index$$,
    $$VALUES (0, 'First paragraph.'), (1, 'Second paragraph.')$$,
    'chunk_full_summary should split on double newline'
);

SELECT is(
    (SELECT count(*)::int FROM chunk_full_summary(E'Para A.\n\n   \n\nPara B.')),
    2,
    'chunk_full_summary should skip whitespace-only paragraphs'
);

SELECT is(
    (SELECT count(*)::int FROM chunk_full_summary('Only one paragraph here.')),
    1,
    'chunk_full_summary with no double newline should return one chunk'
);

-- ── Fixture: pre-seeded embeddings ───────────────────────────────────────────
-- Insert a meeting and utterances, then assign orthogonal basis vectors as
-- embeddings so we can test cosine ordering without calling the OpenAI API.

SELECT insert_test_archive(
    'vec_test_01',
    E'WEBVTT\n\n00:00:01.000 --> 00:00:04.000\nAlice: Quarterly budget review is essential for our financial planning.\n\n00:00:05.000 --> 00:00:08.000\nBob: We need to discuss marketing expenditure this quarter.',
    '{"overallSummary": "Budget planning session.", "finalSummaryString": "Quarterly budgets reviewed.\n\nMarketing expenditure discussed.", "topic": "Q3 Budget", "startTime": "Jun 15, 2024 10:00 AM Eastern Daylight Time"}'::jsonb
);

-- Assign orthogonal unit vectors using PL/pgSQL (float[] → vector(1536) cast).
-- dim_a[1]=1, all others 0  ("direction A")
-- dim_b[2]=1, all others 0  ("direction B", orthogonal to A)
DO $$
DECLARE
    v_dim_a  vector(1536);
    v_dim_b  vector(1536);
    v_arr_a  float[];
    v_arr_b  float[];
BEGIN
    v_arr_a := array_fill(0::float, ARRAY[1536]);
    v_arr_b := array_fill(0::float, ARRAY[1536]);
    v_arr_a[1] := 1.0;
    v_arr_b[2] := 1.0;
    v_dim_a := v_arr_a::vector(1536);
    v_dim_b := v_arr_b::vector(1536);

    -- Meeting short_summary → direction A
    UPDATE meetings SET short_summary_embedding = v_dim_a
    WHERE  meeting_id = 'vec_test_01';

    -- Two summary chunks: chunk 0 → direction A, chunk 1 → direction B
    INSERT INTO meeting_summary_chunks (meeting_id, chunk_index, chunk_text, embedding)
    VALUES
        ('vec_test_01', 0, 'Quarterly budget chunk.',      v_dim_a),
        ('vec_test_01', 1, 'Marketing expenditure chunk.', v_dim_b);
END;
$$;

-- Meeting embedding is set
SELECT ok(
    (SELECT short_summary_embedding IS NOT NULL FROM meetings
     WHERE  meeting_id = 'vec_test_01'),
    'meetings.short_summary_embedding should be set for vec_test_01'
);

-- Two summary chunks with embeddings
SELECT is(
    (SELECT count(*)::int FROM meeting_summary_chunks
     WHERE  meeting_id = 'vec_test_01' AND embedding IS NOT NULL),
    2,
    'vec_test_01 should have 2 summary chunks with embeddings'
);

-- Chunk ordering: chunk 0 nearest to its own embedding → chunk_index 0
SELECT is(
    (SELECT c.chunk_index
     FROM   meeting_summary_chunks c
     CROSS  JOIN (
         SELECT embedding AS q
         FROM   meeting_summary_chunks
         WHERE  meeting_id = 'vec_test_01' AND chunk_index = 0
     ) chunk0_emb
     WHERE  c.meeting_id = 'vec_test_01' AND c.embedding IS NOT NULL
     ORDER  BY c.embedding <=> chunk0_emb.q
     LIMIT  1),
    0,
    'chunk nearest to chunk 0 embedding should be chunk_index 0'
);

-- Meeting: direction A query → vec_test_01 should rank first
SELECT is(
    (SELECT m.meeting_id
     FROM   meetings m
     CROSS  JOIN (
         SELECT short_summary_embedding AS q
         FROM   meetings
         WHERE  meeting_id = 'vec_test_01'
     ) ref_emb
     WHERE  m.short_summary_embedding IS NOT NULL
     ORDER  BY m.short_summary_embedding <=> ref_emb.q
     LIMIT  1),
    'vec_test_01',
    'meeting nearest to its own embedding should be itself'
);

SELECT * FROM finish();
ROLLBACK;
