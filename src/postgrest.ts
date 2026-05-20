import type { Context } from 'hono'
import type { Db, SqlParams } from './db/local.ts'

const ALLOWED_MEETING_COLUMNS = new Set([
  'meeting_id',
  'short_summary',
  'full_summary',
  'meeting_name',
  'date',
  'created_at',
])

const ALLOWED_UTTERANCE_COLUMNS = new Set([
  'id',
  'meeting_id',
  'speaker',
  'text',
  'start_time',
  'end_time',
  'duration',
  'created_at',
])

export function getMeetings(c: Context, db: Db): Response {
  const url = new URL(c.req.url)
  const unsupported = unsupportedParams(url, ALLOWED_MEETING_COLUMNS)
  if (unsupported) return c.json({ message: `Unsupported query parameter: ${unsupported}` }, 400)

  const { limit, offset } = pagination(c)
  const params: SqlParams = []
  const where: string[] = []
  const idFilter = url.searchParams.get('meeting_id')
  if (idFilter?.startsWith('eq.')) {
    where.push('meeting_id = ?')
    params.push(idFilter.slice(3))
  }

  let columns: string
  let order: { column: string; direction: 'ASC' | 'DESC' }
  try {
    columns = selectedColumns(url, ALLOWED_MEETING_COLUMNS, '*')
    order = parseOrder(url.searchParams.get('order'), 'date', 'DESC', ALLOWED_MEETING_COLUMNS)
  } catch (error) {
    return c.json({ message: error instanceof Error ? error.message : String(error) }, 400)
  }
  const whereSql = where.length ? `WHERE ${where.join(' AND ')}` : ''
  const rows = db.all(
    `
    SELECT ${columns} FROM meetings
    ${whereSql}
    ORDER BY ${order.column} ${order.direction}
    LIMIT ? OFFSET ?
    `,
    [...params, limit, offset],
  )

  const total = db.get<{ count: number }>(`SELECT count(*) AS count FROM meetings ${whereSql}`, params)?.count ?? rows.length
  return postgrestJson(c, rows, total)
}

export function getUtterances(c: Context, db: Db): Response {
  const url = new URL(c.req.url)
  const unsupported = unsupportedParams(url, ALLOWED_UTTERANCE_COLUMNS)
  if (unsupported) return c.json({ message: `Unsupported query parameter: ${unsupported}` }, 400)

  const { limit, offset } = pagination(c, 100000)
  const params: SqlParams = []
  const where: string[] = []
  const idFilter = url.searchParams.get('meeting_id')
  if (idFilter?.startsWith('eq.')) {
    where.push('meeting_id = ?')
    params.push(idFilter.slice(3))
  }

  let columns: string
  let order: { column: string; direction: 'ASC' | 'DESC' }
  try {
    columns = selectedColumns(url, ALLOWED_UTTERANCE_COLUMNS, '*')
    order = parseOrder(url.searchParams.get('order'), 'start_time', 'ASC', ALLOWED_UTTERANCE_COLUMNS)
  } catch (error) {
    return c.json({ message: error instanceof Error ? error.message : String(error) }, 400)
  }
  const whereSql = where.length ? `WHERE ${where.join(' AND ')}` : ''
  const rows = db.all(
    `
    SELECT ${columns} FROM utterances
    ${whereSql}
    ORDER BY ${order.column} ${order.direction}
    LIMIT ? OFFSET ?
    `,
    [...params, limit, offset],
  )
  return postgrestJson(c, rows, rows.length)
}

function postgrestJson(c: Context, rows: unknown[], total: number): Response {
  const wantsObject = c.req.header('accept')?.includes('vnd.pgrst.object+json')
  const body = wantsObject ? (rows[0] ?? null) : rows
  const res = c.json(body)
  res.headers.set('Content-Range', `0-${Math.max(rows.length - 1, 0)}/${total}`)
  return res
}

function selectedColumns(url: URL, allowed: Set<string>, fallback: string): string {
  const select = url.searchParams.get('select')
  if (!select || select === '*') return fallback
  const columns = select
    .split(',')
    .map((col) => col.trim())
  const invalid = columns.find((col) => !allowed.has(col))
  if (invalid) throw new Error(`Unsupported select column: ${invalid}`)
  return columns.length ? columns.join(', ') : fallback
}

function parseOrder(
  value: string | null,
  defaultColumn: string,
  defaultDirection: 'ASC' | 'DESC',
  allowed: Set<string>,
): { column: string; direction: 'ASC' | 'DESC' } {
  if (!value) return { column: defaultColumn, direction: defaultDirection }
  const [column, direction] = value.split('.')
  if (!allowed.has(column)) throw new Error(`Unsupported order column: ${column}`)
  return {
    column,
    direction: direction?.toLowerCase() === 'asc' ? 'ASC' : 'DESC',
  }
}

function unsupportedParams(url: URL, allowedColumns: Set<string>): string | null {
  const allowed = new Set(['select', 'order', 'limit', 'offset'])
  for (const key of url.searchParams.keys()) {
    if (allowed.has(key)) continue
    if (allowedColumns.has(key)) continue
    return key
  }
  return null
}

function pagination(c: Context, defaultLimit = 10): { limit: number; offset: number } {
  const url = new URL(c.req.url)
  const limitParam = url.searchParams.get('limit')
  if (limitParam) {
    return { limit: Number(limitParam), offset: Number(url.searchParams.get('offset') ?? 0) }
  }

  const range = c.req.header('range')?.match(/^(\d+)-(\d+)$/)
  if (range) {
    const start = Number(range[1])
    const end = Number(range[2])
    return { limit: end - start + 1, offset: start }
  }

  return { limit: defaultLimit, offset: 0 }
}
