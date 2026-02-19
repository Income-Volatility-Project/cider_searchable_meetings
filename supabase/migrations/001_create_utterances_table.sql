-- Create utterances table to store parsed VTT data
CREATE TABLE IF NOT EXISTS utterances (
    id BIGSERIAL PRIMARY KEY,
    meeting_id TEXT NOT NULL,
    start_time INTEGER NOT NULL CHECK (start_time >= 0),
    end_time INTEGER NOT NULL CHECK (end_time >= start_time),
    duration INTEGER NOT NULL CHECK (duration >= 0),
    speaker TEXT NOT NULL CHECK (length(speaker) > 0),
    text TEXT NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),

    -- Foreign key to archive table
    FOREIGN KEY (meeting_id) REFERENCES archive (meeting_id) ON DELETE CASCADE
);

-- Create indexes for common queries
CREATE INDEX idx_utterances_meeting_id ON utterances(meeting_id);
CREATE INDEX idx_utterances_speaker ON utterances(speaker);
CREATE INDEX idx_utterances_start_time ON utterances(meeting_id, start_time);

-- Add comment explaining the table
COMMENT ON TABLE utterances IS 'Individual utterances extracted from meeting transcripts (VTT format)';
COMMENT ON COLUMN utterances.start_time IS 'Start time in milliseconds from beginning of meeting';
COMMENT ON COLUMN utterances.end_time IS 'End time in milliseconds from beginning of meeting';
COMMENT ON COLUMN utterances.duration IS 'Duration in milliseconds (end_time - start_time)';

-- RLS: public SELECT; writes require service_role key
ALTER TABLE utterances ENABLE ROW LEVEL SECURITY;

CREATE POLICY "utterances_select_public"
    ON utterances
    FOR SELECT
    TO anon, authenticated
    USING (true);
