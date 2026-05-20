import { readFileSync } from 'node:fs'
import { extname, join, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { serve } from '@hono/node-server'
import { Hono, type Context } from 'hono'
import { cors } from 'hono/cors'
import { ingestArchive } from './archive.ts'
import { createLocalDb } from './db/local.ts'
import { getMeetings, getUtterances } from './postgrest.ts'
import {
  parseSearchQuery,
  searchMeetings,
  searchMeetingsSemantic,
  searchUtterances,
  suggestSearchCorrections,
} from './search.ts'
import type { ArchiveInput } from './types.ts'

const db = createLocalDb()
const app = new Hono()
const root = resolve(fileURLToPath(new URL('..', import.meta.url)))
const uiRoot = join(root, 'ui')

app.use('*', cors())

app.post('/rest/v1/archive', async (c) => {
  let payload: ArchiveInput
  try {
    payload = await c.req.json()
  } catch {
    return c.json({ message: 'Invalid JSON body' }, 400)
  }

  try {
    ingestArchive(db, payload)
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

app.get('/rest/v1/meetings', (c) => getMeetings(c, db))
app.get('/rest/v1/utterances', (c) => getUtterances(c, db))

app.post('/rest/v1/rpc/search_utterances', async (c) => {
  const body = await c.req.json().catch(() => ({}))
  return c.json(searchUtterances(db, String(body.query ?? '')))
})

app.post('/rest/v1/rpc/search_meetings', async (c) => {
  const body = await c.req.json().catch(() => ({}))
  return c.json(searchMeetings(db, String(body.query ?? '')))
})

app.post('/rest/v1/rpc/parse_search_query', async (c) => {
  const body = await c.req.json().catch(() => ({}))
  return c.json(parseSearchQuery(String(body.query ?? '')))
})

app.post('/rest/v1/rpc/suggest_search_corrections', async (c) => {
  const body = await c.req.json().catch(() => ({}))
  return c.json(suggestSearchCorrections(db, String(body.query ?? ''), Number(body.limit ?? 5)))
})

app.post('/rest/v1/rpc/search_meetings_semantic', (c) => c.json(searchMeetingsSemantic()))

app.get('/', (c) => serveUiFile(c, 'index.html'))
app.get('/index.html', (c) => serveUiFile(c, 'index.html'))
app.get('/meeting.html', (c) => serveUiFile(c, 'meeting.html'))
app.get('/:file{.+\\.(js|css|html)}', (c) => serveUiFile(c, c.req.param('file')))

function serveUiFile(c: Context, file: string): Response {
  const path = join(uiRoot, file)
  if (!path.startsWith(uiRoot)) return c.text('Not found', 404)
  try {
    const body = readFileSync(path)
    return new Response(body, { headers: { 'content-type': contentType(path) } })
  } catch {
    return c.text('Not found', 404)
  }
}

function contentType(path: string): string {
  switch (extname(path)) {
    case '.html':
      return 'text/html; charset=utf-8'
    case '.css':
      return 'text/css; charset=utf-8'
    case '.js':
      return 'text/javascript; charset=utf-8'
    default:
      return 'application/octet-stream'
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const port = Number(process.env.PORT ?? 8787)
  serve({ fetch: app.fetch, hostname: process.env.HOST ?? '127.0.0.1', port })
  console.log(`Meeting archive server listening on http://localhost:${port}`)
}

export default app
