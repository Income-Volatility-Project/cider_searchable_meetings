import type { Db, RunResult, SqlParams } from './types.ts'

type D1ResultMeta = {
  changes?: number
  last_row_id?: number
}

type D1RunResult = {
  meta?: D1ResultMeta
}

export class D1Db implements Db {
  constructor(private readonly db: D1Database) {}

  async exec(sql: string): Promise<void> {
    await this.db.exec(sql)
  }

  async all<T = Record<string, unknown>>(sql: string, params: SqlParams = []): Promise<T[]> {
    const result = await this.db.prepare(sql).bind(...params).all<T>()
    return result.results ?? []
  }

  async get<T = Record<string, unknown>>(sql: string, params: SqlParams = []): Promise<T | null> {
    return await this.db.prepare(sql).bind(...params).first<T>()
  }

  async run(sql: string, params: SqlParams = []): Promise<RunResult> {
    const result = (await this.db.prepare(sql).bind(...params).run()) as D1RunResult
    return {
      changes: Number(result.meta?.changes ?? 0),
      lastInsertRowid: Number(result.meta?.last_row_id ?? 0),
    }
  }

  async transaction<T>(fn: () => T | Promise<T>): Promise<T> {
    return await fn()
  }
}

export function createD1Db(db: D1Database): D1Db {
  return new D1Db(db)
}
