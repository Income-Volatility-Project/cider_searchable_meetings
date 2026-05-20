import assert from 'node:assert/strict'
import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'

process.env.SQLITE_PATH = join(mkdtempSync(join(tmpdir(), 'meetings-api-')), 'test.sqlite')
const { default: app } = await import('../src/server.ts')

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

function toHexJson(value: unknown): string {
  return `\\x${Buffer.from(JSON.stringify(value), 'utf8').toString('hex')}`
}
