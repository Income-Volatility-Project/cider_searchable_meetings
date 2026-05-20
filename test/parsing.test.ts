import assert from "node:assert/strict";
import test from "node:test";

import { parseSummaryObject } from '../src/parsing/summary.ts'
import { parseVtt, parseVttTimestamp } from '../src/parsing/vtt.ts'

test("parseSummaryObject extracts meeting fields and strips trailing timezone text", () => {
  assert.deepEqual(
    parseSummaryObject('meeting_1', {
      overallSummary: "Short version",
      finalSummaryString: "Full version",
      topic: "Weekly meeting",
      startTime: "Feb 19, 2026 11:05 AM (Eastern Standard Time)",
    }),
    {
      meeting_id: 'meeting_1',
      short_summary: "Short version",
      full_summary: "Full version",
      meeting_name: "Weekly meeting",
      date: "2026-02-19T16:05:00.000Z",
    },
  );

  assert.equal(
    parseSummaryObject('meeting_2', {
      startTime: "Mar 5, 2026 3:00 PM EDT",
    }).date,
    "2026-03-05T20:00:00.000Z",
  );
});

test("parseVttTimestamp parses HH:MM:SS.mmm timestamps to milliseconds", () => {
  assert.equal(parseVttTimestamp("01:02:03.456"), 3_723_456);
  assert.throws(() => parseVttTimestamp("00:61:00.000"), /Minutes must be 0-59/);
  assert.throws(() => parseVttTimestamp("00:00:60.000"), /Seconds must be 0-59/);
});

test("parseVtt normalizes CRLF, skips metadata blocks, and parses multiline cues", () => {
  const vtt = [
    "WEBVTT\r\n\r\n",
    "NOTE internal transcript note\r\n",
    "ignored\r\n\r\n",
    "STYLE\r\n",
    "::cue { color: white }\r\n\r\n",
    "cue-1\r\n",
    "00:00:01.000 --> 00:00:03.250\r\n",
    "Alice: Hello team\r\n",
    "this continues on a second line\r\n\r\n",
    "00:00:03.250 --> 00:00:04.000\r\n",
    "Bob: Thanks: with a colon in text\r\n",
  ].join("");

  assert.deepEqual(parseVtt('meeting_1', vtt), [
    {
      meeting_id: 'meeting_1',
      start_time: 1_000,
      end_time: 3_250,
      duration: 2_250,
      speaker: "Alice",
      text: "Hello team this continues on a second line",
    },
    {
      meeting_id: 'meeting_1',
      start_time: 3_250,
      end_time: 4_000,
      duration: 750,
      speaker: "Bob",
      text: "Thanks: with a colon in text",
    },
  ]);
});

test("parseVtt skips blocks without timestamps and rejects text without a speaker", () => {
  assert.deepEqual(parseVtt('meeting_1', "WEBVTT\n\nnot a cue\njust text\n"), []);

  assert.throws(
    () => parseVtt('meeting_1', "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nMissing speaker\n"),
    /Invalid speaker line: Missing speaker/,
  );
});
