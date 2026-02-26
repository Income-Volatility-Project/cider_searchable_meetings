-- Fix "Function Search Path Mutable" warnings by pinning search_path on every
-- public-schema function that was missing the clause.

-- from 002_process_transcript_functions.sql
ALTER FUNCTION parse_vtt_timestamp(TEXT)                    SET search_path = public;
ALTER FUNCTION process_transcript(TEXT)                     SET search_path = public;
ALTER FUNCTION process_all_transcripts()                    SET search_path = public;
ALTER FUNCTION insert_test_archive(TEXT, TEXT, JSONB)       SET search_path = public;

-- from 003_create_meetings_table.sql
ALTER FUNCTION process_summary(TEXT)                        SET search_path = public;
ALTER FUNCTION process_all_summaries()                      SET search_path = public;

-- from 20260219214252_full_text_search.sql
ALTER FUNCTION search_utterances(TEXT)                      SET search_path = public;
ALTER FUNCTION search_meetings(TEXT)                        SET search_path = public;

-- from 20260219221022_vector_search.sql
ALTER FUNCTION chunk_full_summary(TEXT)                     SET search_path = public;
ALTER FUNCTION embed_meeting(TEXT)                          SET search_path = public;
ALTER FUNCTION embed_utterances(TEXT)                       SET search_path = public;
ALTER FUNCTION embed_all_meetings()                         SET search_path = public;
ALTER FUNCTION embed_all_utterances()                       SET search_path = public;
ALTER FUNCTION search_utterances_semantic(TEXT, INTEGER)    SET search_path = public;
ALTER FUNCTION search_meetings_semantic(TEXT, INTEGER)      SET search_path = public;
ALTER FUNCTION search_meeting_chunks_semantic(TEXT, INTEGER) SET search_path = public;
