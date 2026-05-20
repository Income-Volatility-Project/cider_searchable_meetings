import type { Meeting } from '../types.ts'

const MONTHS: Record<string, number> = {
  jan: 0,
  feb: 1,
  mar: 2,
  apr: 3,
  may: 4,
  jun: 5,
  jul: 6,
  aug: 7,
  sep: 8,
  oct: 9,
  nov: 10,
  dec: 11,
}

export function parseSummaryObject(meetingId: string, summary: Record<string, unknown>): Meeting {
  return {
    meeting_id: meetingId,
    short_summary: stringOrNull(summary.overallSummary),
    full_summary: stringOrNull(summary.finalSummaryString),
    meeting_name: stringOrNull(summary.topic),
    date: parseNewYorkDate(stringOrNull(summary.startTime)),
  }
}

export function chunkFullSummary(fullSummary: string | null): Array<{ chunk_index: number; chunk_text: string }> {
  if (!fullSummary) return []
  return fullSummary
    .split(/\n[ \t]*\n/)
    .map((chunk) => chunk.trim())
    .filter(Boolean)
    .map((chunk_text, chunk_index) => ({ chunk_index, chunk_text }))
}

function stringOrNull(value: unknown): string | null {
  if (value == null) return null
  return String(value)
}

export function stripTimezoneSuffix(value: string): string {
  const match = value.match(/^(.*?\b(?:AM|PM))\b/i)
  return (match ? match[1] : value).trim()
}

export function parseNewYorkDate(value: string | null): string | null {
  if (!value) return null
  const clean = stripTimezoneSuffix(value)
  const match = clean.match(/^([A-Za-z]{3,})\s+(\d{1,2}),\s+(\d{4})\s+(\d{1,2}):(\d{2})\s+(AM|PM)$/i)
  if (!match) return null

  const month = MONTHS[match[1].slice(0, 3).toLowerCase()]
  if (month == null) return null

  const day = Number(match[2])
  const year = Number(match[3])
  let hour = Number(match[4])
  const minute = Number(match[5])
  const ampm = match[6].toUpperCase()
  if (ampm === 'PM' && hour !== 12) hour += 12
  if (ampm === 'AM' && hour === 12) hour = 0

  const utcGuess = Date.UTC(year, month, day, hour, minute)
  const offsetMs = newYorkOffsetMs(new Date(utcGuess))
  return new Date(utcGuess - offsetMs).toISOString()
}

function newYorkOffsetMs(date: Date): number {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone: 'America/New_York',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
    hour12: false,
  }).formatToParts(date)

  const byType = Object.fromEntries(parts.map((part) => [part.type, part.value]))
  const asUtc = Date.UTC(
    Number(byType.year),
    Number(byType.month) - 1,
    Number(byType.day),
    Number(byType.hour),
    Number(byType.minute),
    Number(byType.second),
  )
  return asUtc - date.getTime()
}
