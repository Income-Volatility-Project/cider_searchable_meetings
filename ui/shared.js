// ── Supabase client ──────────────────────────────────────────────────────────
const SUPABASE_URL = 'http://127.0.0.1:54321'
const SUPABASE_PUBLISHABLE_KEY = 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH'
// Note: variable is named `db` to avoid colliding with the `window.supabase` global the SDK sets
const db = window.supabase.createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY)

// ── Shared helpers (mixed into Alpine components) ────────────────────────────

// Convert milliseconds to M:SS
function formatTime(ms) {
  if (ms == null) return ''
  const totalSec = Math.floor(ms / 1000)
  const min = Math.floor(totalSec / 60)
  const sec = (totalSec % 60).toString().padStart(2, '0')
  return `${min}:${sec}`
}

function speakerInitial(name) {
  return name ? name[0].toUpperCase() : '?'
}

// Deterministic color from speaker name
function speakerColor(name) {
  const palette = ['#4f8ef7', '#e67e22', '#2ecc71', '#9b59b6', '#e74c3c', '#1abc9c', '#f39c12']
  if (!name) return palette[0]
  const idx = [...name].reduce((acc, ch) => acc + ch.charCodeAt(0), 0) % palette.length
  return palette[idx]
}
