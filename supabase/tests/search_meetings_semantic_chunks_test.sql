-- pgTAP tests for the updated search_meetings_semantic scoring logic.
--
-- The function calls openai_embed() internally, so we test the underlying
-- CTE scoring logic directly using pre-computed orthogonal unit vectors.
-- No network calls are made.

BEGIN;
SELECT plan(4);

-- ── Fixture ───────────────────────────────────────────────────────────────────
-- Meeting S1: short_summary → direction A, chunks [A, B]
-- Meeting S2: short_summary → direction B, chunks [B]
-- "Querying direction A" uses S1's own embedding as the query vector.

SELECT insert_test_archive(
    'vec_test_s1',
    E'WEBVTT\n\n00:00:01.000 --> 00:00:04.000\nAlice: Chunk search test meeting A.\n\n00:00:05.000 --> 00:00:08.000\nBob: Second utterance.',
    '{"overallSummary": "Chunk ranking test A.", "finalSummaryString": "Topic A.\n\nTopic B.", "topic": "Test A", "startTime": "Jun 15, 2024 10:00 AM Eastern Daylight Time"}'::jsonb
);

SELECT insert_test_archive(
    'vec_test_s2',
    E'WEBVTT\n\n00:00:01.000 --> 00:00:04.000\nCarol: Chunk search test meeting B.',
    '{"overallSummary": "Chunk ranking test B.", "finalSummaryString": "Topic B only.", "topic": "Test B", "startTime": "Jun 15, 2024 10:00 AM Eastern Daylight Time"}'::jsonb
);

DO $$
DECLARE
    v_dim_a vector(1536);
    v_dim_b vector(1536);
    v_arr_a float[];
    v_arr_b float[];
BEGIN
    v_arr_a := array_fill(0::float, ARRAY[1536]);
    v_arr_b := array_fill(0::float, ARRAY[1536]);
    v_arr_a[1] := 1.0;  -- unit vector in dimension 1 ("direction A")
    v_arr_b[2] := 1.0;  -- unit vector in dimension 2, orthogonal to A
    v_dim_a := v_arr_a::vector(1536);
    v_dim_b := v_arr_b::vector(1536);

    -- S1: short_summary → A, two chunks [A, B]
    UPDATE meetings SET short_summary_embedding = v_dim_a WHERE meeting_id = 'vec_test_s1';
    INSERT INTO meeting_summary_chunks (meeting_id, chunk_index, chunk_text, embedding)
    VALUES
        ('vec_test_s1', 0, 'Topic A chunk.', v_dim_a),
        ('vec_test_s1', 1, 'Topic B chunk.', v_dim_b);

    -- S2: short_summary → B, one chunk [B]
    UPDATE meetings SET short_summary_embedding = v_dim_b WHERE meeting_id = 'vec_test_s2';
    INSERT INTO meeting_summary_chunks (meeting_id, chunk_index, chunk_text, embedding)
    VALUES ('vec_test_s2', 0, 'Topic B only chunk.', v_dim_b);
END;
$$;

-- ── Tests ─────────────────────────────────────────────────────────────────────

-- 1. Multi-chunk meeting yields exactly 1 row in best-chunk CTE (GROUP BY works)
SELECT is(
    (WITH q  AS (SELECT short_summary_embedding AS qv
                 FROM   meetings WHERE meeting_id = 'vec_test_s1'),
          bc AS (SELECT c.meeting_id,
                        MAX(1 - (c.embedding <=> (SELECT qv FROM q))) AS chunk_sim
                 FROM   meeting_summary_chunks c
                 WHERE  c.meeting_id = 'vec_test_s1' AND c.embedding IS NOT NULL
                 GROUP  BY c.meeting_id)
     SELECT count(*)::int FROM bc),
    1,
    '2-chunk meeting should collapse to 1 row in best-chunk CTE'
);

-- 2. Best-chunk similarity for S1 queried with direction A is ~1.0
--    (chunk 0 = direction A → cosine distance 0 → similarity 1)
SELECT ok(
    (WITH q  AS (SELECT short_summary_embedding AS qv
                 FROM   meetings WHERE meeting_id = 'vec_test_s1'),
          bc AS (SELECT MAX(1 - (c.embedding <=> (SELECT qv FROM q))) AS chunk_sim
                 FROM   meeting_summary_chunks c
                 WHERE  c.meeting_id = 'vec_test_s1' AND c.embedding IS NOT NULL)
     SELECT abs(chunk_sim - 1.0) < 0.001 FROM bc),
    'best chunk similarity for S1 vs its own direction should be ~1.0'
);

-- 3. Combined score = chunk_sim + 0.25 * short_summary_sim ≈ 1.25 for S1
--    (chunk_sim=1.0 + 0.25*1.0 = 1.25)
SELECT ok(
    (WITH q      AS (SELECT short_summary_embedding AS qv
                     FROM   meetings WHERE meeting_id = 'vec_test_s1'),
          bc     AS (SELECT c.meeting_id,
                            MAX(1 - (c.embedding <=> (SELECT qv FROM q))) AS chunk_sim
                     FROM   meeting_summary_chunks c
                     WHERE  c.meeting_id IN ('vec_test_s1', 'vec_test_s2')
                       AND  c.embedding IS NOT NULL
                     GROUP  BY c.meeting_id),
          scores AS (SELECT m.meeting_id,
                            (bc.chunk_sim
                             + 0.25 * COALESCE(1 - (m.short_summary_embedding <=> (SELECT qv FROM q)), 0.0)
                            )::REAL AS score
                     FROM   meetings m JOIN bc USING (meeting_id))
     SELECT abs(score - 1.25) < 0.001 FROM scores WHERE meeting_id = 'vec_test_s1'),
    'S1 combined score vs direction-A query should be ~1.25 (1.0 + 0.25*1.0)'
);

-- 4. Direction-A query ranks S1 above S2
--    S1 score ≈ 1.25 (chunk A + short A), S2 score ≈ 0.0 (chunk B + short B)
SELECT is(
    (WITH q  AS (SELECT short_summary_embedding AS qv
                 FROM   meetings WHERE meeting_id = 'vec_test_s1'),
          bc AS (SELECT c.meeting_id,
                        MAX(1 - (c.embedding <=> (SELECT qv FROM q))) AS chunk_sim
                 FROM   meeting_summary_chunks c
                 WHERE  c.meeting_id IN ('vec_test_s1', 'vec_test_s2')
                   AND  c.embedding IS NOT NULL
                 GROUP  BY c.meeting_id)
     SELECT m.meeting_id
     FROM   meetings m JOIN bc USING (meeting_id)
     ORDER  BY (bc.chunk_sim
                + 0.25 * COALESCE(1 - (m.short_summary_embedding <=> (SELECT qv FROM q)), 0.0)
               ) DESC
     LIMIT  1),
    'vec_test_s1',
    'direction-A query should rank A-aligned meeting first'
);

SELECT * FROM finish();
ROLLBACK;
