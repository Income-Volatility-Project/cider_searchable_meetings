-- Migration: increase HTTP timeout in openai_embed()
--
-- The default pgsql-http timeout is 5 seconds, which is too short when
-- embedding hundreds of utterances sequentially. Raise to 30 seconds.

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

    PERFORM http_set_curlopt('CURLOPT_TIMEOUT_MS', '30000');

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
    'a vector(1536).  Reads API key from vault secret named OPENAI_API_KEY. '
    'HTTP timeout is 30 seconds.';
