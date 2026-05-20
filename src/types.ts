export type ArchiveInput = {
  meeting_id: string
  summary?: unknown
  transcript?: unknown
}

export type Meeting = {
  meeting_id: string
  short_summary: string | null
  full_summary: string | null
  meeting_name: string | null
  date: string | null
  created_at?: string
}

export type Utterance = {
  id?: number
  meeting_id: string
  start_time: number
  end_time: number
  duration: number
  speaker: string
  text: string
  created_at?: string
}

export type SearchUtteranceResult = {
  id: number
  meeting_id: string
  meeting_name: string | null
  short_summary: string | null
  date: string | null
  speaker: string
  text: string
  start_time: number
  end_time: number
  rank: number
}

export type SearchMeetingResult = {
  meeting_id: string
  meeting_name: string | null
  short_summary: string | null
  full_summary: string | null
  date: string | null
  rank: number
}

export type SearchDateFilter = {
  start: string
  end: string
  label: string
  phrase: string
}

export type ParsedSearchQuery = {
  textQuery: string
  dateFilter: SearchDateFilter | null
}
