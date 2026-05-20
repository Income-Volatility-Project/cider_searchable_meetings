import { Hono, type Context } from 'hono'
import { ingestArchive } from './archive.ts'
import type { Db } from './db/types.ts'
import { getMeetings, getUtterances } from './postgrest.ts'
import {
  parseSearchQuery,
  searchMeetings,
  searchMeetingsSemantic,
  searchUtterances,
  suggestSearchCorrections,
} from './search.ts'
import type { ArchiveInput } from './types.ts'

export type WorkerBindings = {
  DB: D1Database
  ALLOWED_ORIGINS?: string
}

type AppContext = Context<{ Bindings: WorkerBindings }>
type MaybePromise<T> = T | Promise<T>

export type AppOptions = {
  getDb: (c: AppContext) => MaybePromise<Db>
  allowedOrigins?: string[]
  allowAllOrigins?: boolean
}

export function createApp(options: AppOptions): Hono<{ Bindings: WorkerBindings }> {
  const app = new Hono<{ Bindings: WorkerBindings }>()

  app.use('*', async (c, next) => {
    const origin = c.req.header('origin')
    const allowedOrigin = allowedCorsOrigin(origin, configuredOrigins(c, options), options.allowAllOrigins === true)
    if (allowedOrigin) {
      c.header('Access-Control-Allow-Origin', allowedOrigin)
      c.header('Vary', 'Origin')
      c.header('Access-Control-Allow-Headers', 'Content-Type, Prefer, Range')
      c.header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
      c.header('Access-Control-Expose-Headers', 'Content-Range')
    }

    if (c.req.method === 'OPTIONS') {
      return c.body(null, allowedOrigin || !origin ? 204 : 403)
    }

    await next()
  })

  app.post('/rest/v1/archive', async (c) => {
    let payload: ArchiveInput
    try {
      payload = await c.req.json()
    } catch {
      return c.json({ message: 'Invalid JSON body' }, 400)
    }

    try {
      await ingestArchive(await options.getDb(c), payload)
      const prefer = c.req.header('prefer') ?? ''
      return prefer.includes('return=minimal') ? c.body(null, 201) : c.json(payload, 201)
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      if (message.includes('UNIQUE constraint failed')) {
        return c.json({ message: 'duplicate key value violates unique constraint "archive_pkey"' }, 409)
      }
      return c.json({ message }, 400)
    }
  })

  app.get('/rest/v1/meetings', async (c) => getMeetings(c, await options.getDb(c)))
  app.get('/rest/v1/utterances', async (c) => getUtterances(c, await options.getDb(c)))

  app.post('/rest/v1/rpc/search_utterances', async (c) => {
    const body = await c.req.json().catch(() => ({}))
    return c.json(await searchUtterances(await options.getDb(c), String(body.query ?? '')))
  })

  app.post('/rest/v1/rpc/search_meetings', async (c) => {
    const body = await c.req.json().catch(() => ({}))
    return c.json(await searchMeetings(await options.getDb(c), String(body.query ?? '')))
  })

  app.post('/rest/v1/rpc/parse_search_query', async (c) => {
    const body = await c.req.json().catch(() => ({}))
    return c.json(parseSearchQuery(String(body.query ?? '')))
  })

  app.post('/rest/v1/rpc/suggest_search_corrections', async (c) => {
    const body = await c.req.json().catch(() => ({}))
    return c.json(
      await suggestSearchCorrections(await options.getDb(c), String(body.query ?? ''), Number(body.limit ?? 5)),
    )
  })

  app.post('/rest/v1/rpc/search_meetings_semantic', (c) => c.json(searchMeetingsSemantic()))

  return app
}

function configuredOrigins(c: AppContext, options: AppOptions): string[] {
  if (options.allowedOrigins) return options.allowedOrigins
  return splitConfig(c.env?.ALLOWED_ORIGINS)
}

function splitConfig(value: string | undefined): string[] {
  return (value ?? '')
    .split(',')
    .map((part) => part.trim())
    .filter(Boolean)
}

function allowedCorsOrigin(origin: string | undefined, allowedOrigins: string[], allowAll: boolean): string | null {
  if (!origin) return null
  if (allowedOrigins.length === 0) return allowAll ? origin : null
  return allowedOrigins.includes(origin) ? origin : null
}
