BEGIN;
SELECT plan(7);

-- 1. openai_embed_batch exists with correct signature
SELECT has_function(
    'public', 'openai_embed_batch',
    ARRAY['text[]'],
    'openai_embed_batch(text[]) should exist'
);

-- 2. Empty array input → returns empty array without HTTP call
SELECT is(
    array_length(openai_embed_batch(ARRAY[]::TEXT[]), 1),
    NULL,
    'openai_embed_batch with empty array returns empty array'
);

-- 3. NULL input → returns empty array without HTTP call
SELECT is(
    array_length(openai_embed_batch(NULL::TEXT[]), 1),
    NULL,
    'openai_embed_batch with NULL input returns empty array'
);

-- 4. embed_1_short_summary exists with correct signature
SELECT has_function(
    'public', 'embed_1_short_summary',
    ARRAY[]::TEXT[],
    'embed_1_short_summary() should exist'
);

-- 5. embed_1_utterance_batch exists with correct signature
SELECT has_function(
    'public', 'embed_1_utterance_batch',
    ARRAY[]::TEXT[],
    'embed_1_utterance_batch() should exist'
);

-- 6. embed_1_utterance_batch with all utterances already embedded → (0, true, NULL)
DO $$
BEGIN
    -- Temporarily set all utterances as embedded
    UPDATE utterances SET embedding = array_fill(0::float, ARRAY[1536])::vector(1536)
    WHERE embedding IS NULL;
END;
$$;

SELECT results_eq(
    'SELECT utterances_embedded, success, error_message FROM embed_1_utterance_batch()',
    $$VALUES (0, true, NULL::TEXT)$$,
    'embed_1_utterance_batch returns (0, true, NULL) when all utterances are embedded'
);

-- 7. embed_1_short_summary with all summaries embedded → returns no rows
DO $$
BEGIN
    UPDATE meetings
    SET short_summary_embedding = array_fill(0::float, ARRAY[1536])::vector(1536)
    WHERE short_summary_embedding IS NULL
      AND short_summary IS NOT NULL
      AND length(trim(short_summary)) > 0;
END;
$$;

SELECT is(
    (SELECT count(*)::INTEGER FROM embed_1_short_summary()),
    0,
    'embed_1_short_summary returns no rows when all summaries are embedded'
);

SELECT * FROM finish();
ROLLBACK;
