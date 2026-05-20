import assert from "node:assert/strict";
import test from "node:test";
import { join } from "node:path";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";

import { createLocalDb } from "../src/db/local.ts";
import { refreshSearchTerms } from "../src/search_terms.ts";
import {
  parseSearchQuery,
  searchMeetings,
  searchMeetingsSemantic,
  searchUtterances,
  suggestSearchCorrections,
} from "../src/search.ts";

class RecordingDb {
  calls: Array<{ sql: string; params: Array<string | number | null> }> = [];
  private readonly rows: unknown[];

  constructor(rows: unknown[] = []) {
    this.rows = rows;
  }

  all<T>(sql: string, params: Array<string | number | null> = []): T[] {
    this.calls.push({ sql, params });
    return this.rows as T[];
  }
}

test("search_utterances returns the UI/RPC row shape", async () => {
  const db = new RecordingDb([
    {
      id: 1,
      meeting_id: "meeting_1",
      meeting_name: "Budget Review",
      short_summary: "Budget planning",
      date: "2026-02-16T12:00:00.000Z",
      speaker: "Alice",
      text: "We should review the budget.",
      start_time: 1000,
      end_time: 5000,
      rank: 1.25,
    },
  ]);

  const rows = searchUtterances(db as never, "budget planning");

  assert.deepEqual(rows, [
    {
      id: 1,
      meeting_id: "meeting_1",
      meeting_name: "Budget Review",
      short_summary: "Budget planning",
      date: "2026-02-16T12:00:00.000Z",
      speaker: "Alice",
      text: "We should review the budget.",
      start_time: 1000,
      end_time: 5000,
      rank: 1.25,
    },
  ]);
  assert.equal(db.calls.length, 1);
  assert.match(db.calls[0].sql, /FROM utterances_fts/);
  assert.match(db.calls[0].sql, /JOIN meetings m/);
  assert.deepEqual(db.calls[0].params, ['"budget"* "planning"*']);
});

test("search_meetings returns the UI/RPC row shape", async () => {
  const db = new RecordingDb([
    {
      meeting_id: "meeting_1",
      meeting_name: "Budget Review",
      short_summary: "Budget planning",
      full_summary: "The group discussed marketing expenditure.",
      date: "2026-02-16T12:00:00.000Z",
      rank: 0.75,
    },
  ]);

  const rows = searchMeetings(db as never, "marketing expenditure");

  assert.deepEqual(rows, [
    {
      meeting_id: "meeting_1",
      meeting_name: "Budget Review",
      short_summary: "Budget planning",
      full_summary: "The group discussed marketing expenditure.",
      date: "2026-02-16T12:00:00.000Z",
      rank: 0.75,
    },
  ]);
  assert.equal(db.calls.length, 1);
  assert.match(db.calls[0].sql, /FROM meetings_fts/);
  assert.match(db.calls[0].sql, /JOIN meetings m/);
  assert.deepEqual(db.calls[0].params, ['"marketing"* "expenditure"*']);
});

test("search_meetings_semantic is a no-op SQLite stub", async () => {
  const rows = searchMeetingsSemantic();

  assert.deepEqual(rows, []);
});

test("empty full-text queries return no rows without touching the DB", async () => {
  const db = new RecordingDb();

  assert.deepEqual(searchUtterances(db as never, "  "), []);
  assert.deepEqual(searchMeetings(db as never, "\n\t"), []);
  assert.equal(db.calls.length, 0);
});

test("parseSearchQuery extracts simple date filters and leaves text query", () => {
  assert.deepEqual(parseSearchQuery("budget Feb 2026"), {
    textQuery: "budget",
    dateFilter: {
      start: "2026-02-01T05:00:00.000Z",
      end: "2026-03-01T05:00:00.000Z",
      label: "Feb 2026",
      phrase: "Feb 2026",
    },
  });

  assert.deepEqual(parseSearchQuery("planning 2026-02-16"), {
    textQuery: "planning",
    dateFilter: {
      start: "2026-02-16T05:00:00.000Z",
      end: "2026-02-17T05:00:00.000Z",
      label: "Feb 16, 2026",
      phrase: "2026-02-16",
    },
  });

  assert.equal(parseSearchQuery("budget 20").dateFilter, null);
});

test("date filters add meeting date predicates to transcript search", () => {
  const db = new RecordingDb();

  searchUtterances(db as never, "budget Feb 2026");

  assert.match(db.calls[0].sql, /m\.date >= \? AND m\.date < \?/);
  assert.deepEqual(db.calls[0].params, [
    '"budget"*',
    "2026-02-01T05:00:00.000Z",
    "2026-03-01T05:00:00.000Z",
  ]);
});

test("date-only meeting search does not require FTS text", () => {
  const db = new RecordingDb([
    {
      meeting_id: "meeting_1",
      meeting_name: "Budget Review",
      short_summary: "Budget planning",
      full_summary: "The group discussed marketing expenditure.",
      date: "2026-02-16T12:00:00.000Z",
      rank: 0,
    },
  ]);

  const rows = searchMeetings(db as never, "February 2026");

  assert.equal(rows.length, 1);
  assert.match(db.calls[0].sql, /FROM meetings m/);
  assert.doesNotMatch(db.calls[0].sql, /meetings_fts MATCH/);
  assert.deepEqual(db.calls[0].params, [
    "2026-02-01T05:00:00.000Z",
    "2026-03-01T05:00:00.000Z",
  ]);
});

test("web-search OR is preserved as a SQLite FTS operator", () => {
  const db = new RecordingDb();

  searchUtterances(db as never, "budget OR planning");

  assert.deepEqual(db.calls[0].params, ['"budget"* OR "planning"*']);
});

test("prefix search matches incomplete words in SQLite FTS", () => {
  const db = createLocalDb(join(mkdtempSync(join(tmpdir(), "meetings-search-")), "test.sqlite"));

  db.run("INSERT INTO archive (meeting_id, summary, transcript) VALUES (?, ?, ?)", ["meeting_1", null, null]);
  db.run(
    `
    INSERT INTO meetings (meeting_id, meeting_name, short_summary, full_summary, date)
    VALUES (?, ?, ?, ?, ?)
    `,
    ["meeting_1", "Health Review", "Stress hormones", "Discussion of cortisol response.", "2026-02-16T12:00:00.000Z"],
  );
  const result = db.run(
    `
    INSERT INTO utterances (meeting_id, start_time, end_time, duration, speaker, text)
    VALUES (?, ?, ?, ?, ?, ?)
    `,
    ["meeting_1", 1000, 5000, 4000, "Alice", "The cortisol response was elevated."],
  );
  db.run("INSERT INTO utterances_fts (utterance_id, meeting_id, text) VALUES (?, ?, ?)", [
    Number(result.lastInsertRowid),
    "meeting_1",
    "The cortisol response was elevated.",
  ]);

  const rows = searchUtterances(db, "Cortiso");

  assert.equal(rows.length, 1);
  assert.equal(rows[0].meeting_id, "meeting_1");
  assert.match(rows[0].text, /cortisol/i);
});

test("suggestSearchCorrections returns likely vocabulary terms for typos", () => {
  const db = createLocalDb(join(mkdtempSync(join(tmpdir(), "meetings-corrections-")), "test.sqlite"));
  insertSearchFixture(db);

  const rows = suggestSearchCorrections(db, "cortsol");

  assert.equal(rows[0]?.term, "cortisol");
  assert.ok(rows[0]?.score > 0.7);
});

test("suggestSearchCorrections skips exact, blank, and date-only queries", () => {
  const db = createLocalDb(join(mkdtempSync(join(tmpdir(), "meetings-corrections-")), "test.sqlite"));
  insertSearchFixture(db);

  assert.deepEqual(suggestSearchCorrections(db, "cortisol"), []);
  assert.deepEqual(suggestSearchCorrections(db, "  "), []);
  assert.deepEqual(suggestSearchCorrections(db, "February 2026"), []);
});

test("suggestSearchCorrections dedupes multi-word candidates and respects limit", () => {
  const db = createLocalDb(join(mkdtempSync(join(tmpdir(), "meetings-corrections-")), "test.sqlite"));
  insertSearchFixture(db);

  const rows = suggestSearchCorrections(db, "cortsol cortsol budgt", 1);

  assert.equal(rows.length, 1);
  assert.equal(new Set(rows.map((row) => row.term)).size, rows.length);
});

function insertSearchFixture(db: ReturnType<typeof createLocalDb>): void {
  db.run("INSERT INTO archive (meeting_id, summary, transcript) VALUES (?, ?, ?)", ["meeting_1", null, null]);
  db.run(
    `
    INSERT INTO meetings (meeting_id, meeting_name, short_summary, full_summary, date)
    VALUES (?, ?, ?, ?, ?)
    `,
    ["meeting_1", "Health Review", "Cortisol budget", "Cortisol planning and budget review.", "2026-02-16T12:00:00.000Z"],
  );
  db.run("INSERT INTO meetings_fts (meeting_id, short_summary, full_summary) VALUES (?, ?, ?)", [
    "meeting_1",
    "Cortisol budget",
    "Cortisol planning and budget review.",
  ]);
  const result = db.run(
    `
    INSERT INTO utterances (meeting_id, start_time, end_time, duration, speaker, text)
    VALUES (?, ?, ?, ?, ?, ?)
    `,
    ["meeting_1", 1000, 5000, 4000, "Alice", "The cortisol response shaped the budget."],
  );
  db.run("INSERT INTO utterances_fts (utterance_id, meeting_id, text) VALUES (?, ?, ?)", [
    Number(result.lastInsertRowid),
    "meeting_1",
    "The cortisol response shaped the budget.",
  ]);
  refreshSearchTerms(db);
}
