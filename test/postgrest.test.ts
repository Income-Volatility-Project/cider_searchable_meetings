import assert from 'node:assert/strict'
import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'
import { createApp } from '../src/app.ts'
import { createLocalDb } from '../src/db/local.ts'

const db = createLocalDb(join(mkdtempSync(join(tmpdir(), 'meetings-api-')), 'test.sqlite'))
const app = createApp({
  getDb: () => db,
  allowAllOrigins: true,
})

test('archive upload accepts valid records and rejects duplicates', async () => {
  const payload = {
    meeting_id: 'api_upload_meeting',
    summary: toHexJson({ overallSummary: 'Short', finalSummaryString: 'Full', topic: 'Upload Test' }),
    transcript: toHexJson({ vtt: '00:00:01.000 --> 00:00:02.000\nAlice: Hi' }),
  }

  let response = await app.request('/rest/v1/archive', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Prefer: 'return=minimal',
    },
    body: JSON.stringify(payload),
  })
  assert.equal(response.status, 201)
  assert.equal(await response.text(), '')

  response = await app.request('/rest/v1/archive', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Prefer: 'return=minimal',
    },
    body: JSON.stringify(payload),
  })
  assert.equal(response.status, 409)
  assert.match(await response.text(), /duplicate key value/)
})

test('archive upload rejects invalid JSON', async () => {
  const response = await app.request('/rest/v1/archive', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: '{',
  })
  assert.equal(response.status, 400)
  assert.match(await response.text(), /Invalid JSON body/)
})

test('unsupported PostgREST query parameters fail clearly', async () => {
  const response = await app.request('/rest/v1/meetings?bogus=eq.x')
  assert.equal(response.status, 400)
  assert.match(await response.text(), /Unsupported query parameter: bogus/)
})

test('unsupported select and order columns fail clearly', async () => {
  let response = await app.request('/rest/v1/meetings?select=meeting_id,bogus')
  assert.equal(response.status, 400)
  assert.match(await response.text(), /Unsupported select column: bogus/)

  response = await app.request('/rest/v1/utterances?order=bogus.asc')
  assert.equal(response.status, 400)
  assert.match(await response.text(), /Unsupported order column: bogus/)
})

test('parse_search_query exposes date filter metadata for the UI', async () => {
  const response = await app.request('/rest/v1/rpc/parse_search_query', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: 'budget Feb 2026' }),
  })

  assert.equal(response.status, 200)
  assert.deepEqual(await response.json(), {
    textQuery: 'budget',
    dateFilter: {
      start: '2026-02-01T05:00:00.000Z',
      end: '2026-03-01T05:00:00.000Z',
      label: 'Feb 2026',
      phrase: 'Feb 2026',
    },
  })
})

test('suggest_search_corrections exposes typo suggestions for the UI', async () => {
  const payload = {
    meeting_id: 'api_correction_meeting',
    summary: toHexJson({
      overallSummary: 'The group discussed cortisol measurements.',
      finalSummaryString: 'Cortisol measurements were reviewed.',
      topic: 'Health Review',
    }),
    transcript: toHexJson({ vtt: '00:00:01.000 --> 00:00:02.000\nAlice: Cortisol came up again.' }),
  }

  const upload = await app.request('/rest/v1/archive', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Prefer: 'return=minimal',
    },
    body: JSON.stringify(payload),
  })
  assert.equal(upload.status, 201)

  const response = await app.request('/rest/v1/rpc/suggest_search_corrections', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: 'cortsol', limit: 5 }),
  })

  assert.equal(response.status, 200)
  const rows = (await response.json()) as Array<{ term?: string }>
  assert.equal(rows[0]?.term, 'cortisol')
})

test('API token protects DB-backed routes when configured', async () => {
  const db = createLocalDb(join(mkdtempSync(join(tmpdir(), 'meetings-auth-')), 'test.sqlite'))
  const protectedApp = createApp({
    getDb: () => db,
    apiToken: 'secret-token',
    allowAllOrigins: true,
  })

  let response = await protectedApp.request('/rest/v1/meetings')
  assert.equal(response.status, 401)

  response = await protectedApp.request('/rest/v1/meetings', {
    headers: { Authorization: 'Bearer secret-token' },
  })
  assert.equal(response.status, 200)
})

test('CORS preflight only allows configured origins', async () => {
  const db = createLocalDb(join(mkdtempSync(join(tmpdir(), 'meetings-cors-')), 'test.sqlite'))
  const corsApp = createApp({
    getDb: () => db,
    allowedOrigins: ['https://ui.example.test'],
  })

  let response = await corsApp.request('/rest/v1/meetings', {
    method: 'OPTIONS',
    headers: { Origin: 'https://ui.example.test' },
  })
  assert.equal(response.status, 204)
  assert.equal(response.headers.get('Access-Control-Allow-Origin'), 'https://ui.example.test')

  response = await corsApp.request('/rest/v1/meetings', {
    method: 'OPTIONS',
    headers: { Origin: 'https://other.example.test' },
  })
  assert.equal(response.status, 403)
  assert.equal(response.headers.get('Access-Control-Allow-Origin'), null)
})

function toHexJson(value: unknown): string {
  return `\\x${Buffer.from(JSON.stringify(value), 'utf8').toString('hex')}`
}
