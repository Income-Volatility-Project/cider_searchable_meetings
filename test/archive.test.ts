import assert from 'node:assert/strict'
import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'

import { ingestArchive } from '../src/archive.ts'
import { createLocalDb } from '../src/db/local.ts'

test('ingestArchive inserts archive and derived meeting, utterance, chunk, and FTS rows', () => {
  const db = createLocalDb(join(mkdtempSync(join(tmpdir(), 'meetings-')), 'test.sqlite'))
  const summary = {
    overallSummary: 'The group discussed budget planning.',
    finalSummaryString: 'Budget planning details.\n\nMarketing expenditure details.',
    topic: 'Budget Review',
    startTime: 'Feb 19, 2026 11:05 AM (Eastern Standard Time)',
  }
  const transcript = {
    vtt: [
      'WEBVTT',
      '',
      '1',
      '00:00:01.000 --> 00:00:03.000',
      'Alice: We should review the budget.',
      '',
      '2',
      '00:00:03.500 --> 00:00:05.000',
      'Bob: Marketing expenditure is next.',
    ].join('\n'),
  }

  ingestArchive(db, {
    meeting_id: 'meeting_1',
    summary: toHexJson(summary),
    transcript: toHexJson(transcript),
  })

  assert.equal(db.get<{ count: number }>('SELECT count(*) AS count FROM archive')?.count, 1)
  assert.equal(db.get<{ meeting_name: string }>('SELECT meeting_name FROM meetings')?.meeting_name, 'Budget Review')
  assert.equal(db.get<{ count: number }>('SELECT count(*) AS count FROM utterances')?.count, 2)
  assert.equal(db.get<{ count: number }>('SELECT count(*) AS count FROM meeting_summary_chunks')?.count, 2)
  assert.equal(
    db.get<{ count: number }>("SELECT count(*) AS count FROM utterances_fts WHERE utterances_fts MATCH 'budget'")?.count,
    1,
  )
})

test('ingestArchive rejects duplicate meeting ids', () => {
  const db = createLocalDb(join(mkdtempSync(join(tmpdir(), 'meetings-')), 'test.sqlite'))
  const input = {
    meeting_id: 'meeting_1',
    summary: toHexJson({ overallSummary: 'Short', finalSummaryString: 'Full', topic: 'Topic' }),
    transcript: toHexJson({ vtt: '00:00:01.000 --> 00:00:02.000\nAlice: Hi' }),
  }

  ingestArchive(db, input)
  assert.throws(() => ingestArchive(db, input), /UNIQUE constraint failed/)
})

test('ingestArchive preserves raw archive and meeting row when transcript parsing fails', () => {
  const db = createLocalDb(join(mkdtempSync(join(tmpdir(), 'meetings-')), 'test.sqlite'))

  ingestArchive(db, {
    meeting_id: 'bad_transcript',
    summary: toHexJson({ overallSummary: 'Short', finalSummaryString: 'Full', topic: 'Topic' }),
    transcript: toHexJson({ vtt: '00:00:01.000 --> 00:00:02.000\nMissing speaker' }),
  })

  assert.equal(db.get<{ count: number }>('SELECT count(*) AS count FROM archive')?.count, 1)
  assert.equal(db.get<{ count: number }>('SELECT count(*) AS count FROM meetings')?.count, 1)
  assert.equal(db.get<{ count: number }>('SELECT count(*) AS count FROM utterances')?.count, 0)
})

function toHexJson(value: unknown): string {
  return `\\x${Buffer.from(JSON.stringify(value), 'utf8').toString('hex')}`
}
