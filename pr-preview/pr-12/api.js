// Tiny PostgREST-compatible fetch wrapper for the UI.
// It intentionally implements only the subset of the Supabase client API used here.
(function () {
  const apiBase = (window.API_URL || window.POSTGREST_URL || window.location.origin).replace(/\/$/, '')

  function restBase() {
    if (!apiBase) throw new Error('API_URL or SUPABASE_URL must be configured')
    return apiBase.endsWith('/rest/v1') ? apiBase : `${apiBase}/rest/v1`
  }

  function headers(extra = {}) {
    return { ...extra }
  }

  async function toResult(response, { maybeSingle = false, wantCount = false } = {}) {
    const text = await response.text()
    let body = null
    if (text) {
      try {
        body = JSON.parse(text)
      } catch {
        body = text
      }
    }

    if (!response.ok) {
      const message = body?.message || body?.error || body || `${response.status} ${response.statusText}`
      return { data: null, error: { message }, count: null }
    }

    const data = maybeSingle ? (Array.isArray(body) ? (body[0] || null) : body) : (body || [])
    const contentRange = response.headers.get('content-range') || ''
    const countMatch = contentRange.match(/\/(\d+)$/)
    return {
      data,
      error: null,
      count: wantCount && countMatch ? Number(countMatch[1]) : null,
    }
  }

  function tableQuery(table) {
    const state = {
      table,
      select: '*',
      filters: [],
      orders: [],
      limit: null,
      offset: null,
      maybeSingle: false,
      wantCount: false,
    }

    const builder = {
      select(columns, options = {}) {
        state.select = (columns || '*').replace(/\s*,\s*/g, ',')
        state.wantCount = options.count === 'exact'
        return builder
      },
      eq(column, value) {
        state.filters.push([column, `eq.${value}`])
        return builder
      },
      order(column, options = {}) {
        state.orders.push(`${column}.${options.ascending === false ? 'desc' : 'asc'}`)
        return builder
      },
      limit(value) {
        state.limit = value
        return builder
      },
      range(from, to) {
        state.offset = from
        state.limit = to - from + 1
        return builder
      },
      maybeSingle() {
        state.maybeSingle = true
        state.limit = state.limit || 1
        return builder
      },
      then(resolve, reject) {
        return executeTableQuery(state).then(resolve, reject)
      },
      catch(reject) {
        return executeTableQuery(state).catch(reject)
      },
      finally(callback) {
        return executeTableQuery(state).finally(callback)
      },
    }
    return builder
  }

  async function executeTableQuery(state) {
    try {
      const url = new URL(`${restBase()}/${state.table}`)
      url.searchParams.set('select', state.select)
      for (const [column, value] of state.filters) url.searchParams.append(column, value)
      if (state.orders.length) url.searchParams.set('order', state.orders.join(','))
      if (state.limit != null) url.searchParams.set('limit', state.limit)
      if (state.offset != null) url.searchParams.set('offset', state.offset)

      const response = await fetch(url, {
        headers: headers({
          Accept: 'application/json',
          ...(state.wantCount ? { Prefer: 'count=exact' } : {}),
        }),
      })
      return toResult(response, { maybeSingle: state.maybeSingle, wantCount: state.wantCount })
    } catch (e) {
      return { data: null, error: { message: e.message || String(e) }, count: null }
    }
  }

  async function rpc(functionName, params = {}) {
    try {
      const response = await fetch(`${restBase()}/rpc/${functionName}`, {
        method: 'POST',
        headers: headers({
          Accept: 'application/json',
          'Content-Type': 'application/json',
        }),
        body: JSON.stringify(params),
      })
      return toResult(response)
    } catch (e) {
      return { data: null, error: { message: e.message || String(e) }, count: null }
    }
  }

  async function uploadArchive(record) {
    try {
      const response = await fetch(`${restBase()}/archive`, {
        method: 'POST',
        headers: headers({
          Accept: 'application/json',
          'Content-Type': 'application/json',
          Prefer: 'return=minimal',
        }),
        body: JSON.stringify(record),
      })

      if (response.status === 201) {
        return { ok: true, skipped: false, status: response.status, message: null }
      }
      if (response.status === 409) {
        return { ok: true, skipped: true, status: response.status, message: 'Already exists' }
      }

      const result = await toResult(response)
      return {
        ok: false,
        skipped: false,
        status: response.status,
        message: result.error?.message || `${response.status} ${response.statusText}`,
      }
    } catch (e) {
      return {
        ok: false,
        skipped: false,
        status: 0,
        message: e.message || String(e),
      }
    }
  }

  window.createDbClient = function createDbClient() {
    return {
      from: tableQuery,
      rpc,
      uploadArchive,
    }
  }

  // Backward-compatible shim for shared.js, without loading the Supabase SDK.
  window.supabase = {
    createClient: window.createDbClient,
  }
})()
