import type { Db } from './db/local.ts'
import { decodeArchiveValue, parseJsonObject } from './parsing/archive.ts'
import { chunkFullSummary, parseSummaryObject } from './parsing/summary.ts'
import { parseVtt } from './parsing/vtt.ts'
import type { ArchiveInput, Meeting, Utterance } from './types.ts'

export function ingestArchive(db: Db, input: ArchiveInput): void {
  if (!input.meeting_id) throw new Error('meeting_id is required')
  const summaryText = decodeArchiveValue(input.summary)
  const transcriptText = decodeArchiveValue(input.transcript)

  db.transaction(() => {
    db.run('INSERT INTO archive (meeting_id, summary, transcript) VALUES (?, ?, ?)', [
      input.meeting_id,
      summaryText,
      transcriptText,
    ])
  })

  try {
    db.transaction(() => {
      rebuildDerivedRows(db, input.meeting_id, summaryText, transcriptText)
    })
  } catch {
    // Match the old trigger path: preserve the raw archive row even if
    // downstream parsing fails. The insert endpoint still reports success.
  }
}

export function rebuildDerivedRows(
  db: Db,
  meetingId: string,
  summaryText: string | null,
  transcriptText: string | null,
): void {
  db.run('DELETE FROM utterances_fts WHERE meeting_id = ?', [meetingId])
  db.run('DELETE FROM meetings_fts WHERE meeting_id = ?', [meetingId])
  db.run('DELETE FROM meeting_summary_chunks WHERE meeting_id = ?', [meetingId])
  db.run('DELETE FROM utterances WHERE meeting_id = ?', [meetingId])
  db.run('DELETE FROM meetings WHERE meeting_id = ?', [meetingId])

  try {
    const summary = parseJsonObject(summaryText, 'summary')
    const meeting = parseSummaryObject(meetingId, summary)
    insertMeeting(db, meeting)
    syncMeetingFts(db, meeting)
    syncSummaryChunks(db, meeting)
  } catch {
    // Summary parsing failure should not block transcript parsing.
  }

  try {
    const transcript = parseJsonObject(transcriptText, 'transcript')
    const utterances = parseVtt(meetingId, typeof transcript.vtt === 'string' ? transcript.vtt : null)
    insertUtterances(db, utterances)
  } catch {
    // Transcript parsing failure should not remove the raw archive or meeting row.
  }
}

function insertMeeting(db: Db, meeting: Meeting): void {
  db.run(
    `
    INSERT INTO meetings (meeting_id, short_summary, full_summary, meeting_name, date)
    VALUES (?, ?, ?, ?, ?)
    `,
    [meeting.meeting_id, meeting.short_summary, meeting.full_summary, meeting.meeting_name, meeting.date],
  )
}

function insertUtterances(db: Db, utterances: Utterance[]): void {
  for (const utterance of utterances) {
    const result = db.run(
      `
      INSERT INTO utterances (meeting_id, start_time, end_time, duration, speaker, text)
      VALUES (?, ?, ?, ?, ?, ?)
      `,
      [
        utterance.meeting_id,
        utterance.start_time,
        utterance.end_time,
        utterance.duration,
        utterance.speaker,
        utterance.text,
      ],
    )
    db.run('INSERT INTO utterances_fts (utterance_id, meeting_id, text) VALUES (?, ?, ?)', [
      Number(result.lastInsertRowid),
      utterance.meeting_id,
      utterance.text,
    ])
  }
}

function syncMeetingFts(db: Db, meeting: Meeting): void {
  db.run('INSERT INTO meetings_fts (meeting_id, short_summary, full_summary) VALUES (?, ?, ?)', [
    meeting.meeting_id,
    meeting.short_summary,
    meeting.full_summary,
  ])
}

function syncSummaryChunks(db: Db, meeting: Meeting): void {
  for (const chunk of chunkFullSummary(meeting.full_summary)) {
    db.run('INSERT INTO meeting_summary_chunks (meeting_id, chunk_index, chunk_text) VALUES (?, ?, ?)', [
      meeting.meeting_id,
      chunk.chunk_index,
      chunk.chunk_text,
    ])
  }
}
