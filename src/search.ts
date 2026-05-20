import type { Db } from './db/local.ts'
import type { SearchMeetingResult, SearchUtteranceResult } from './types.ts'

export function searchUtterances(db: Db, query: string): SearchUtteranceResult[] {
  if (!query.trim()) return []
  return db.all<SearchUtteranceResult>(
    `
    SELECT
      u.id,
      u.meeting_id,
      m.meeting_name,
      m.short_summary,
      m.date,
      u.speaker,
      u.text,
      u.start_time,
      u.end_time,
      bm25(utterances_fts) * -1 AS rank
    FROM utterances_fts
    JOIN utterances u ON u.id = utterances_fts.utterance_id
    JOIN meetings m ON m.meeting_id = u.meeting_id
    WHERE utterances_fts MATCH ?
    ORDER BY rank DESC
    `,
    [ftsQuery(query)],
  )
}

export function searchMeetings(db: Db, query: string): SearchMeetingResult[] {
  if (!query.trim()) return []
  return db.all<SearchMeetingResult>(
    `
    SELECT
      m.meeting_id,
      m.meeting_name,
      m.short_summary,
      m.full_summary,
      m.date,
      bm25(meetings_fts) * -1 AS rank
    FROM meetings_fts
    JOIN meetings m ON m.meeting_id = meetings_fts.meeting_id
    WHERE meetings_fts MATCH ?
    ORDER BY rank DESC
    `,
    [ftsQuery(query)],
  )
}

export function searchMeetingsSemantic(): [] {
  return []
}

export const search_utterances = searchUtterances
export const search_meetings = searchMeetings
export const search_meetings_semantic = searchMeetingsSemantic

function ftsQuery(query: string): string {
  const parts = query
    .trim()
    .split(/\s+/)
    .map((term) => term.replace(/["]/g, ''))
    .filter(Boolean)
    .map((term) => (term.toUpperCase() === 'OR' ? 'OR' : `"${term}"*`))

  const cleaned: string[] = []
  for (const part of parts) {
    if (part === 'OR' && (cleaned.length === 0 || cleaned[cleaned.length - 1] === 'OR')) continue
    cleaned.push(part)
  }
  if (cleaned[cleaned.length - 1] === 'OR') cleaned.pop()
  return cleaned.join(' ')
}
