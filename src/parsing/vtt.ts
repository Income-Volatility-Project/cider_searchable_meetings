import type { Utterance } from '../types.ts'

export function parseVttTimestamp(value: string): number {
  const clean = value.trim()
  const match = clean.match(/^(\d{2}):(\d{2}):(\d{2})\.(\d{3})/)
  if (!match) throw new Error(`Expected HH:MM:SS.mmm format, got ${value}`)

  const hours = Number(match[1])
  const minutes = Number(match[2])
  const seconds = Number(match[3])
  const milliseconds = Number(match[4])

  if (hours < 0 || hours >= 24) throw new Error(`Hours must be 0-23, got ${hours}`)
  if (minutes < 0 || minutes >= 60) throw new Error(`Minutes must be 0-59, got ${minutes}`)
  if (seconds < 0 || seconds >= 60) throw new Error(`Seconds must be 0-59, got ${seconds}`)

  return hours * 3600000 + minutes * 60000 + seconds * 1000 + milliseconds
}

export function parseVtt(meetingId: string, vttContent: string | null): Utterance[] {
  if (vttContent == null) throw new Error('No VTT data found in transcript')

  const normalized = vttContent.replace(/\r\n/g, '\n').replace(/\r/g, '\n')
  const blocks = normalized.split(/\n[ \t]*\n+/)
  const utterances: Utterance[] = []

  for (const rawBlock of blocks) {
    const block = rawBlock.trim()
    if (!block) continue
    if (block.startsWith('WEBVTT') || block.startsWith('NOTE') || block.startsWith('STYLE')) continue

    const lines = block.split('\n').map((line) => line.trim())
    const timestampIndex = lines.findIndex((line) => line.includes('-->'))
    if (timestampIndex < 0) continue

    const textLines = lines.slice(timestampIndex + 1).filter(Boolean)
    if (textLines.length === 0) continue

    const [startRaw, endRaw] = lines[timestampIndex].split('-->')
    const start_time = parseVttTimestamp(startRaw)
    const end_time = parseVttTimestamp(endRaw)
    const firstLine = textLines[0]
    const colon = firstLine.indexOf(':')
    if (colon < 0) throw new Error(`Invalid speaker line: ${firstLine}`)

    const speaker = firstLine.slice(0, colon).trim()
    const firstText = firstLine.slice(colon + 1).trim()
    const text = [firstText, ...textLines.slice(1).map((line) => line.trim())].join(' ').trim()

    utterances.push({
      meeting_id: meetingId,
      start_time,
      end_time,
      duration: end_time - start_time,
      speaker,
      text,
    })
  }

  return utterances
}
