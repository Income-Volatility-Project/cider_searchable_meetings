-- Vector (semantic) search using pgvector + OpenAI text-embedding-3-small.
--
-- Architecture:
--   • utterances.embedding             vector(1536) — one per utterance
--   • meetings.short_summary_embedding vector(1536) — one per meeting
--   • meeting_summary_chunks                        — one row per full_summary paragraph
--       (meeting_id, chunk_index, chunk_text, embedding vector(1536))
--
-- Embedding generation uses the synchronous `http` extension (pgsql-http) so
-- openai_embed() can be a plain FUNCTION callable from any context (triggers,
-- CTEs, search helpers, etc.).  No background worker or two-phase commit needed.
--
-- API key setup (local dev):
--   SELECT vault.create_secret('sk-...', 'OPENAI_API_KEY');
-- The remote project should already have the key in vault.

-- ── Extensions ───────────────────────────────────────────────────────────────

CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS http;   -- pgsql-http: synchronous HTTP in SQL

-- ── Schema changes ───────────────────────────────────────────────────────────

ALTER TABLE utterances
    ADD COLUMN embedding vector(1536);

COMMENT ON COLUMN utterances.embedding IS
    'text-embedding-3-small embedding of utterances.text';


ALTER TABLE meetings
    ADD COLUMN short_summary_embedding vector(1536);

COMMENT ON COLUMN meetings.short_summary_embedding IS
    'text-embedding-3-small embedding of meetings.short_summary';


CREATE TABLE meeting_summary_chunks (
    id          BIGSERIAL PRIMARY KEY,
    meeting_id  TEXT    NOT NULL REFERENCES meetings(meeting_id) ON DELETE CASCADE,
    chunk_index INTEGER NOT NULL,   -- zero-based paragraph order
    chunk_text  TEXT    NOT NULL,
    embedding   vector(1536),

    UNIQUE (meeting_id, chunk_index)
);

CREATE INDEX idx_summary_chunks_meeting_id ON meeting_summary_chunks(meeting_id);

COMMENT ON TABLE meeting_summary_chunks IS
    'full_summary split into per-topic paragraphs with individual embeddings';

-- RLS: public SELECT; writes require service_role key
ALTER TABLE meeting_summary_chunks ENABLE ROW LEVEL SECURITY;

CREATE POLICY "summary_chunks_select_public"
    ON meeting_summary_chunks
    FOR SELECT
    TO anon, authenticated
    USING (true);


-- ── HNSW indexes (cosine distance) ──────────────────────────────────────────
-- HNSW gives fast approximate nearest-neighbour queries without a training step.

CREATE INDEX idx_utterances_embedding
    ON utterances USING hnsw (embedding vector_cosine_ops);

CREATE INDEX idx_meetings_short_summary_embedding
    ON meetings USING hnsw (short_summary_embedding vector_cosine_ops);

CREATE INDEX idx_summary_chunks_embedding
    ON meeting_summary_chunks USING hnsw (embedding vector_cosine_ops);


-- ── openai_embed — synchronous embedding via pgsql-http ──────────────────────
-- Uses the http extension for a blocking HTTP call so this can be a regular
-- FUNCTION (no background worker, no two-phase commit required).

CREATE OR REPLACE FUNCTION openai_embed(p_text TEXT)
RETURNS vector(1536)
LANGUAGE plpgsql
SECURITY DEFINER   -- needed to read vault.decrypted_secrets
SET search_path = public, vault
AS $$
DECLARE
    v_api_key  TEXT;
    v_response http_response;
BEGIN
    SELECT decrypted_secret INTO v_api_key
    FROM vault.decrypted_secrets
    WHERE name = 'OPENAI_API_KEY';

    IF v_api_key IS NULL THEN
        RAISE EXCEPTION 'OPENAI_API_KEY not found in vault. '
            'Run: SELECT vault.create_secret(''sk-…'', ''OPENAI_API_KEY'');';
    END IF;

    SELECT * INTO v_response
    FROM http((
        'POST',
        'https://api.openai.com/v1/embeddings',
        ARRAY[
            http_header('Authorization', 'Bearer ' || v_api_key)
        ],
        'application/json',
        jsonb_build_object(
            'model', 'text-embedding-3-small',
            'input', p_text
        )::text
    )::http_request);

    IF v_response.status <> 200 THEN
        RAISE EXCEPTION 'OpenAI API error (HTTP %): %',
            v_response.status, v_response.content;
    END IF;

    RETURN (v_response.content::jsonb -> 'data' -> 0 -> 'embedding')
               ::text::vector(1536);
END;
$$;

COMMENT ON FUNCTION openai_embed(TEXT) IS
    'Synchronously call OpenAI text-embedding-3-small via pgsql-http and return '
    'a vector(1536).  Reads API key from vault secret named OPENAI_API_KEY.';


-- ── chunk_full_summary — paragraph splitter ──────────────────────────────────
-- full_summary is double-newline-delimited topic paragraphs.

CREATE OR REPLACE FUNCTION chunk_full_summary(p_full_summary TEXT)
RETURNS TABLE (chunk_index INTEGER, chunk_text TEXT)
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT
        (ROW_NUMBER() OVER ())::INTEGER - 1  AS chunk_index,
        trim(chunk)                           AS chunk_text
    FROM   unnest(regexp_split_to_array(p_full_summary, E'\\n[ \\t]*\\n')) AS chunk
    WHERE  trim(chunk) <> '';
$$;

COMMENT ON FUNCTION chunk_full_summary(TEXT) IS
    'Split a full_summary into its topic paragraphs (double-newline delimited). '
    'Returns (chunk_index, chunk_text) rows in order.';


-- ── embed_meeting — embed one meeting's summaries ────────────────────────────

CREATE OR REPLACE FUNCTION embed_meeting(p_meeting_id TEXT)
RETURNS TABLE (success BOOLEAN, error_message TEXT)
LANGUAGE plpgsql
AS $$
DECLARE
    v_short_summary TEXT;
    v_full_summary  TEXT;
    v_chunk         RECORD;
BEGIN
    SELECT short_summary, full_summary
    INTO   v_short_summary, v_full_summary
    FROM   meetings
    WHERE  meeting_id = p_meeting_id;

    IF NOT FOUND THEN
        RETURN QUERY SELECT false, 'Meeting not found';
        RETURN;
    END IF;

    BEGIN
        -- short_summary embedding
        IF v_short_summary IS NOT NULL AND length(trim(v_short_summary)) > 0 THEN
            UPDATE meetings
            SET    short_summary_embedding = openai_embed(v_short_summary)
            WHERE  meeting_id = p_meeting_id;
        END IF;

        -- full_summary chunks: rebuild from scratch (idempotent)
        DELETE FROM meeting_summary_chunks WHERE meeting_id = p_meeting_id;

        IF v_full_summary IS NOT NULL AND length(trim(v_full_summary)) > 0 THEN
            FOR v_chunk IN SELECT * FROM chunk_full_summary(v_full_summary) LOOP
                INSERT INTO meeting_summary_chunks
                       (meeting_id, chunk_index, chunk_text, embedding)
                VALUES (p_meeting_id,
                        v_chunk.chunk_index,
                        v_chunk.chunk_text,
                        openai_embed(v_chunk.chunk_text));
            END LOOP;
        END IF;

        RETURN QUERY SELECT true, NULL::TEXT;

    EXCEPTION WHEN OTHERS THEN
        RETURN QUERY SELECT false, SQLERRM;
    END;
END;
$$;

COMMENT ON FUNCTION embed_meeting(TEXT) IS
    'Generate embeddings for one meeting: short_summary_embedding + full_summary chunks. '
    'Rebuilds chunks from scratch so the call is idempotent.';


-- ── embed_utterances — embed utterances for one meeting ──────────────────────

CREATE OR REPLACE FUNCTION embed_utterances(p_meeting_id TEXT)
RETURNS TABLE (utterances_embedded INTEGER, success BOOLEAN, error_message TEXT)
LANGUAGE plpgsql
AS $$
DECLARE
    v_count     INTEGER := 0;
    v_utterance RECORD;
BEGIN
    BEGIN
        FOR v_utterance IN
            SELECT id, text
            FROM   utterances
            WHERE  meeting_id = p_meeting_id
        LOOP
            UPDATE utterances
            SET    embedding = openai_embed(v_utterance.text)
            WHERE  id = v_utterance.id;

            v_count := v_count + 1;
        END LOOP;

        RETURN QUERY SELECT v_count, true, NULL::TEXT;

    EXCEPTION WHEN OTHERS THEN
        RETURN QUERY SELECT v_count, false, SQLERRM;
    END;
END;
$$;

COMMENT ON FUNCTION embed_utterances(TEXT) IS
    'Generate embeddings for every utterance in a meeting.';


-- ── embed_all_meetings — batch helper ────────────────────────────────────────

CREATE OR REPLACE FUNCTION embed_all_meetings()
RETURNS TABLE (meeting_id TEXT, success BOOLEAN, error_message TEXT)
LANGUAGE plpgsql
AS $$
DECLARE
    v_meeting RECORD;
    v_result  RECORD;
BEGIN
    FOR v_meeting IN
        SELECT m.meeting_id
        FROM   meetings m
        WHERE  m.short_summary_embedding IS NULL
    LOOP
        SELECT * INTO v_result FROM embed_meeting(v_meeting.meeting_id);
        RETURN QUERY SELECT v_meeting.meeting_id, v_result.success, v_result.error_message;
    END LOOP;
END;
$$;

COMMENT ON FUNCTION embed_all_meetings() IS
    'Batch-embed all meetings that do not yet have a short_summary_embedding.';


-- ── embed_all_utterances — batch helper ──────────────────────────────────────

CREATE OR REPLACE FUNCTION embed_all_utterances()
RETURNS TABLE (
    meeting_id          TEXT,
    utterances_embedded INTEGER,
    success             BOOLEAN,
    error_message       TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_meeting RECORD;
    v_result  RECORD;
BEGIN
    FOR v_meeting IN
        SELECT DISTINCT u.meeting_id
        FROM   utterances u
        WHERE  u.embedding IS NULL
    LOOP
        SELECT * INTO v_result FROM embed_utterances(v_meeting.meeting_id);
        RETURN QUERY SELECT v_meeting.meeting_id,
                            v_result.utterances_embedded,
                            v_result.success,
                            v_result.error_message;
    END LOOP;
END;
$$;

COMMENT ON FUNCTION embed_all_utterances() IS
    'Batch-embed all utterances that do not yet have an embedding.';


-- ── search_utterances_semantic ───────────────────────────────────────────────
-- Generates a query embedding on the fly via openai_embed(), then returns the
-- top match_count utterances ordered by cosine similarity (descending).

CREATE OR REPLACE FUNCTION search_utterances_semantic(
    query       TEXT,
    match_count INTEGER DEFAULT 10
)
RETURNS TABLE (
    id         BIGINT,
    meeting_id TEXT,
    speaker    TEXT,
    text       TEXT,
    start_time INTEGER,
    end_time   INTEGER,
    similarity REAL
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_query_embedding vector(1536);
BEGIN
    v_query_embedding := openai_embed(query);

    RETURN QUERY
    SELECT
        u.id,
        u.meeting_id,
        u.speaker,
        u.text,
        u.start_time,
        u.end_time,
        (1 - (u.embedding <=> v_query_embedding))::REAL AS similarity
    FROM   utterances u
    WHERE  u.embedding IS NOT NULL
    ORDER  BY u.embedding <=> v_query_embedding
    LIMIT  match_count;
END;
$$;

COMMENT ON FUNCTION search_utterances_semantic(TEXT, INTEGER) IS
    'Semantic search over utterances.text. Embeds the query then returns the '
    'top match_count utterances by cosine similarity, descending.';


-- ── search_meetings_semantic ─────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION search_meetings_semantic(
    query       TEXT,
    match_count INTEGER DEFAULT 10
)
RETURNS TABLE (
    meeting_id    TEXT,
    meeting_name  TEXT,
    short_summary TEXT,
    date          TIMESTAMP WITH TIME ZONE,
    similarity    REAL
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_query_embedding vector(1536);
BEGIN
    v_query_embedding := openai_embed(query);

    RETURN QUERY
    SELECT
        m.meeting_id,
        m.meeting_name,
        m.short_summary,
        m.date,
        (1 - (m.short_summary_embedding <=> v_query_embedding))::REAL AS similarity
    FROM   meetings m
    WHERE  m.short_summary_embedding IS NOT NULL
    ORDER  BY m.short_summary_embedding <=> v_query_embedding
    LIMIT  match_count;
END;
$$;

COMMENT ON FUNCTION search_meetings_semantic(TEXT, INTEGER) IS
    'Semantic search over meetings.short_summary. Returns top match_count meetings '
    'by cosine similarity, descending.';


-- ── search_meeting_chunks_semantic ───────────────────────────────────────────

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
AS $$
DECLARE
    v_query_embedding vector(1536);
BEGIN
    v_query_embedding := openai_embed(query);

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
    'by cosine similarity, descending, with their parent meeting_name.';
