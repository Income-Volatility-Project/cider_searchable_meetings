PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS archive (
  meeting_id TEXT PRIMARY KEY,
  summary TEXT,
  transcript TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS meetings (
  meeting_id TEXT PRIMARY KEY,
  short_summary TEXT,
  full_summary TEXT,
  meeting_name TEXT,
  date TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  FOREIGN KEY (meeting_id) REFERENCES archive(meeting_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS utterances (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  meeting_id TEXT NOT NULL,
  start_time INTEGER NOT NULL CHECK (start_time >= 0),
  end_time INTEGER NOT NULL CHECK (end_time >= start_time),
  duration INTEGER NOT NULL CHECK (duration >= 0),
  speaker TEXT NOT NULL CHECK (length(speaker) > 0),
  text TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  FOREIGN KEY (meeting_id) REFERENCES archive(meeting_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS meeting_summary_chunks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  meeting_id TEXT NOT NULL,
  chunk_index INTEGER NOT NULL,
  chunk_text TEXT NOT NULL,
  FOREIGN KEY (meeting_id) REFERENCES meetings(meeting_id) ON DELETE CASCADE,
  UNIQUE (meeting_id, chunk_index)
);

CREATE INDEX IF NOT EXISTS idx_meetings_date ON meetings(date);
CREATE INDEX IF NOT EXISTS idx_utterances_meeting_id ON utterances(meeting_id);
CREATE INDEX IF NOT EXISTS idx_utterances_start_time ON utterances(meeting_id, start_time);
CREATE INDEX IF NOT EXISTS idx_summary_chunks_meeting_id ON meeting_summary_chunks(meeting_id);

CREATE VIRTUAL TABLE IF NOT EXISTS meetings_fts USING fts5(
  meeting_id UNINDEXED,
  short_summary,
  full_summary,
  tokenize = 'porter'
);

CREATE VIRTUAL TABLE IF NOT EXISTS utterances_fts USING fts5(
  utterance_id UNINDEXED,
  meeting_id UNINDEXED,
  text,
  tokenize = 'porter'
);

CREATE VIRTUAL TABLE IF NOT EXISTS meetings_vocab USING fts5vocab(meetings_fts, 'row');
CREATE VIRTUAL TABLE IF NOT EXISTS utterances_vocab USING fts5vocab(utterances_fts, 'row');

CREATE TABLE IF NOT EXISTS search_terms (
  term TEXT PRIMARY KEY,
  doc_count INTEGER NOT NULL DEFAULT 0
);

CREATE VIRTUAL TABLE IF NOT EXISTS search_terms_trigram USING fts5(
  term,
  tokenize = 'trigram'
);
