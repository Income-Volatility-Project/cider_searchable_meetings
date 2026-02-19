-- Create archive table — the primary store for raw meeting data
-- Mirrors the SQLite schema in old/database.py (archive_bootstrap)
CREATE TABLE IF NOT EXISTS archive (
    meeting_id TEXT PRIMARY KEY,
    summary    BYTEA,
    transcript BYTEA
);

COMMENT ON TABLE archive IS 'Raw meeting data: BYTEA-encoded JSON summary and VTT transcript';

-- RLS: no permissive policies — service_role key only
ALTER TABLE archive ENABLE ROW LEVEL SECURITY;

CREATE POLICY "allow_anon_inserts_archive"
	ON archive 
	FOR INSERT
	TO anon, authenticated
    	WITH CHECK (true);

