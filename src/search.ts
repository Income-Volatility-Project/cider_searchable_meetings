import type { Db } from './db/local.ts'
import type {
  ParsedSearchQuery,
  SearchCorrection,
  SearchDateFilter,
  SearchMeetingResult,
  SearchUtteranceResult,
} from './types.ts'

const MONTHS: Array<{ short: string; long: string }> = [
  { short: 'Jan', long: 'January' },
  { short: 'Feb', long: 'February' },
  { short: 'Mar', long: 'March' },
  { short: 'Apr', long: 'April' },
  { short: 'May', long: 'May' },
  { short: 'Jun', long: 'June' },
  { short: 'Jul', long: 'July' },
  { short: 'Aug', long: 'August' },
  { short: 'Sep', long: 'September' },
  { short: 'Oct', long: 'October' },
  { short: 'Nov', long: 'November' },
  { short: 'Dec', long: 'December' },
]

export function searchUtterances(db: Db, query: string): SearchUtteranceResult[] {
  const parsed = parseSearchQuery(query)
  if (!parsed.textQuery) return []

  const params: Array<string | number | null> = [ftsQuery(parsed.textQuery)]
  const dateSql = dateFilterSql(parsed.dateFilter, params)
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
    ${dateSql}
    ORDER BY rank DESC
    `,
    params,
  )
}

export function searchMeetings(db: Db, query: string): SearchMeetingResult[] {
  const parsed = parseSearchQuery(query)
  if (!parsed.textQuery && !parsed.dateFilter) return []

  const params: Array<string | number | null> = []
  const dateSql = dateFilterSql(parsed.dateFilter, params)
  if (!parsed.textQuery) {
    return db.all<SearchMeetingResult>(
      `
      SELECT
        m.meeting_id,
        m.meeting_name,
        m.short_summary,
        m.full_summary,
        m.date,
        0 AS rank
      FROM meetings m
      WHERE 1 = 1
      ${dateSql}
      ORDER BY m.date DESC
      `,
      params,
    )
  }

  params.unshift(ftsQuery(parsed.textQuery))
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
    ${dateSql}
    ORDER BY rank DESC
    `,
    params,
  )
}

export function searchMeetingsSemantic(): [] {
  return []
}

export function suggestSearchCorrections(db: Db, query: string, limit = 5): SearchCorrection[] {
  const parsed = parseSearchQuery(query)
  const terms = correctionQueryTerms(parsed.textQuery)
  if (terms.length === 0) return []

  const requestedLimit = Number.isFinite(limit) ? Math.floor(limit) : 5
  const maxResults = Math.max(1, Math.min(requestedLimit, 20))
  const suggestions = new Map<string, SearchCorrection>()

  for (const term of terms) {
    if (isKnownSearchTerm(db, term)) continue

    const trigramQuery = trigramFtsQuery(term)
    if (!trigramQuery) continue

    const candidates = db.all<{ term: string; doc_count: number }>(
      `
      SELECT search_terms.term, search_terms.doc_count
      FROM search_terms_trigram
      JOIN search_terms ON search_terms.term = search_terms_trigram.term
      WHERE search_terms_trigram MATCH ?
      ORDER BY bm25(search_terms_trigram)
      LIMIT ?
      `,
      [trigramQuery, maxResults * 20],
    )

    for (const candidate of candidates) {
      const candidateTerm = candidate.term.toLowerCase()
      if (candidateTerm === term) continue

      const distance = editDistance(term, candidateTerm)
      const longest = Math.max(term.length, candidateTerm.length)
      if (longest === 0) continue

      const similarity = 1 - distance / longest
      if (similarity < 0.45) continue

      const frequencyBoost = Math.min(Math.log10(Math.max(candidate.doc_count, 1)) / 10, 0.2)
      const score = Number(Math.min(1, similarity + frequencyBoost).toFixed(4))
      const existing = suggestions.get(candidateTerm)
      if (!existing || score > existing.score) suggestions.set(candidateTerm, { term: candidate.term, score })
    }
  }

  return Array.from(suggestions.values())
    .sort((a, b) => b.score - a.score || a.term.localeCompare(b.term))
    .slice(0, maxResults)
}

export const search_utterances = searchUtterances
export const search_meetings = searchMeetings
export const search_meetings_semantic = searchMeetingsSemantic
export const suggest_search_corrections = suggestSearchCorrections

export function parseSearchQuery(query: string): ParsedSearchQuery {
  const input = query.trim()
  if (!input) return { textQuery: '', dateFilter: null }

  const match = findDateMatch(input)
  if (!match) return { textQuery: input, dateFilter: null }

  return {
    textQuery: cleanTextQuery(input.slice(0, match.start) + ' ' + input.slice(match.end)),
    dateFilter: match.filter,
  }
}

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

function correctionQueryTerms(query: string): string[] {
  const seen = new Set<string>()
  const terms: string[] = []
  for (const rawTerm of query.trim().split(/\s+/)) {
    const term = normalizeCorrectionTerm(rawTerm)
    if (!term || term === 'or' || term.length < 3 || seen.has(term)) continue
    seen.add(term)
    terms.push(term)
  }
  return terms
}

function normalizeCorrectionTerm(term: string): string {
  return term
    .toLowerCase()
    .replace(/["']/g, '')
    .replace(/^[^a-z0-9]+|[^a-z0-9]+$/g, '')
}

function isKnownSearchTerm(db: Db, term: string): boolean {
  return db.get<{ term: string }>('SELECT term FROM search_terms WHERE term = ? LIMIT 1', [term]) !== null
}

function trigramFtsQuery(term: string): string {
  const trigrams = new Set<string>()
  for (let i = 0; i <= term.length - 3; i++) {
    const trigram = term.slice(i, i + 3)
    if (/^[a-z0-9]{3}$/.test(trigram)) trigrams.add(trigram)
  }
  return Array.from(trigrams)
    .map((trigram) => `"${trigram}"`)
    .join(' OR ')
}

function editDistance(a: string, b: string): number {
  if (a === b) return 0
  if (a.length === 0) return b.length
  if (b.length === 0) return a.length

  let previous = Array.from({ length: b.length + 1 }, (_, index) => index)
  for (let i = 1; i <= a.length; i++) {
    const current = [i]
    for (let j = 1; j <= b.length; j++) {
      const substitutionCost = a[i - 1] === b[j - 1] ? 0 : 1
      current[j] = Math.min(
        current[j - 1] + 1,
        previous[j] + 1,
        previous[j - 1] + substitutionCost,
      )
    }
    previous = current
  }
  return previous[b.length]
}

function dateFilterSql(filter: SearchDateFilter | null, params: Array<string | number | null>): string {
  if (!filter) return ''
  params.push(filter.start, filter.end)
  return 'AND m.date >= ? AND m.date < ?'
}

function cleanTextQuery(query: string): string {
  return query
    .replace(/\s+/g, ' ')
    .replace(/^\s+|\s+$/g, '')
    .replace(/\b(?:on|in|during)\s*$/i, '')
    .replace(/^\s+|\s+$/g, '')
}

function findDateMatch(input: string): { start: number; end: number; filter: SearchDateFilter } | null {
  return (
    matchIsoDate(input) ??
    matchSlashDate(input) ??
    matchMonthDayYear(input) ??
    matchMonthYear(input) ??
    matchYear(input)
  )
}

function matchIsoDate(input: string): { start: number; end: number; filter: SearchDateFilter } | null {
  const match = /\b(\d{4})-(\d{1,2})-(\d{1,2})\b/.exec(input)
  if (!match) return null
  return dateMatch(input, match.index, match.index + match[0].length, Number(match[1]), Number(match[2]), Number(match[3]))
}

function matchSlashDate(input: string): { start: number; end: number; filter: SearchDateFilter } | null {
  const match = /\b(\d{1,2})\/(\d{1,2})\/(\d{2}|\d{4})\b/.exec(input)
  if (!match) return null
  const year = normalizeYear(Number(match[3]))
  return dateMatch(input, match.index, match.index + match[0].length, year, Number(match[1]), Number(match[2]))
}

function matchMonthDayYear(input: string): { start: number; end: number; filter: SearchDateFilter } | null {
  const match = monthRegex(String.raw`\s+(\d{1,2})(?:st|nd|rd|th)?[,]?\s+(\d{4})`).exec(input)
  if (!match) return null
  const month = monthNumber(match[1])
  return dateMatch(input, match.index, match.index + match[0].length, Number(match[3]), month, Number(match[2]))
}

function matchMonthYear(input: string): { start: number; end: number; filter: SearchDateFilter } | null {
  const match = monthRegex(String.raw`\s+(\d{4})`).exec(input)
  if (!match) return null
  const month = monthNumber(match[1])
  const year = Number(match[2])
  if (!isValidYear(year)) return null
  return rangeMatch(input, match.index, match.index + match[0].length, year, month, null)
}

function matchYear(input: string): { start: number; end: number; filter: SearchDateFilter } | null {
  const match = /\b(19\d{2}|20\d{2})\b/.exec(input)
  if (!match) return null
  const year = Number(match[1])
  return rangeMatch(input, match.index, match.index + match[0].length, year, null, null)
}

function monthRegex(suffix: string): RegExp {
  const names = MONTHS.flatMap((month) => [month.short, month.long]).join('|')
  return new RegExp(String.raw`\b(${names})\.?` + suffix + String.raw`\b`, 'i')
}

function dateMatch(
  input: string,
  start: number,
  end: number,
  year: number,
  month: number,
  day: number,
): { start: number; end: number; filter: SearchDateFilter } | null {
  if (!isValidDate(year, month, day)) return null
  return rangeMatch(input, start, end, year, month, day)
}

function rangeMatch(
  input: string,
  start: number,
  end: number,
  year: number,
  month: number | null,
  day: number | null,
): { start: number; end: number; filter: SearchDateFilter } | null {
  const range = dateRange(year, month, day)
  if (!range) return null
  return {
    start,
    end,
    filter: {
      ...range,
      phrase: input.slice(start, end),
    },
  }
}

function dateRange(year: number, month: number | null, day: number | null): Omit<SearchDateFilter, 'phrase'> | null {
  if (!isValidYear(year)) return null

  if (month == null) {
    return {
      start: newYorkLocalIso(year, 1, 1),
      end: newYorkLocalIso(year + 1, 1, 1),
      label: String(year),
    }
  }

  if (month < 1 || month > 12) return null
  if (day == null) {
    const nextMonth = month === 12 ? 1 : month + 1
    const nextYear = month === 12 ? year + 1 : year
    return {
      start: newYorkLocalIso(year, month, 1),
      end: newYorkLocalIso(nextYear, nextMonth, 1),
      label: `${MONTHS[month - 1].short} ${year}`,
    }
  }

  if (!isValidDate(year, month, day)) return null
  const next = new Date(Date.UTC(year, month - 1, day + 1))
  return {
    start: newYorkLocalIso(year, month, day),
    end: newYorkLocalIso(next.getUTCFullYear(), next.getUTCMonth() + 1, next.getUTCDate()),
    label: `${MONTHS[month - 1].short} ${day}, ${year}`,
  }
}

function monthNumber(value: string): number {
  const key = value.slice(0, 3).toLowerCase()
  return MONTHS.findIndex((month) => month.short.toLowerCase() === key) + 1
}

function normalizeYear(year: number): number {
  return year < 100 ? 2000 + year : year
}

function isValidYear(year: number): boolean {
  return year >= 1900 && year <= 2099
}

function isValidDate(year: number, month: number, day: number): boolean {
  if (!isValidYear(year) || month < 1 || month > 12 || day < 1 || day > 31) return false
  const date = new Date(Date.UTC(year, month - 1, day))
  return date.getUTCFullYear() === year && date.getUTCMonth() === month - 1 && date.getUTCDate() === day
}

function newYorkLocalIso(year: number, month: number, day: number): string {
  const utcGuess = Date.UTC(year, month - 1, day, 0, 0, 0)
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
