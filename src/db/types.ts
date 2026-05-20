export type SqlParams = Array<string | number | null>

export type RunResult = {
  changes: number
  lastInsertRowid: number | bigint
}

export type Db = {
  exec(sql: string): void | Promise<void>
  all<T = Record<string, unknown>>(sql: string, params?: SqlParams): T[] | Promise<T[]>
  get<T = Record<string, unknown>>(sql: string, params?: SqlParams): T | null | Promise<T | null>
  run(sql: string, params?: SqlParams): RunResult | Promise<RunResult>
  transaction<T>(fn: () => T | Promise<T>): T | Promise<T>
}
