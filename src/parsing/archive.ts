export function decodeArchiveValue(value: unknown): string | null {
  if (value == null) return null

  if (typeof value === 'object') {
    return JSON.stringify(value)
  }

  const raw = String(value)
  const hex = raw.startsWith('\\x') ? raw.slice(2) : null
  if (!hex) return raw
  if (!/^[0-9a-fA-F]*$/.test(hex) || hex.length % 2 !== 0) {
    throw new Error('Invalid hex archive payload')
  }
  return new TextDecoder().decode(hexToBytes(hex))
}

export function parseJsonObject(text: string | null, label: string): Record<string, unknown> {
  if (!text) return {}
  const parsed = JSON.parse(text)
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new Error(`${label} must decode to a JSON object`)
  }
  return parsed as Record<string, unknown>
}

function hexToBytes(hex: string): Uint8Array {
  const bytes = new Uint8Array(hex.length / 2)
  for (let i = 0; i < bytes.length; i += 1) {
    bytes[i] = Number.parseInt(hex.slice(i * 2, i * 2 + 2), 16)
  }
  return bytes
}
