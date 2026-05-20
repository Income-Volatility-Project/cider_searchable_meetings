import { mkdirSync, readFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { DatabaseSync } from 'node:sqlite'
import { refreshSearchTerms } from '../search_terms.ts'

export type SqlParams = Array<string | number | null>

export type Db = {
  exec(sql: string): void
  all<T = Record<string, unknown>>(sql: string, params?: SqlParams): T[]
  get<T = Record<string, unknown>>(sql: string, params?: SqlParams): T | null
  run(sql: string, params?: SqlParams): { changes: number; lastInsertRowid: number | bigint }
  transaction<T>(fn: () => T): T
}

export class LocalDb implements Db {
  private readonly db: DatabaseSync

  constructor(path: string) {
    this.db = new DatabaseSync(path)
    this.db.exec('PRAGMA foreign_keys = ON')
  }

  exec(sql: string): void {
    this.db.exec(sql)
  }

  all<T = Record<string, unknown>>(sql: string, params: SqlParams = []): T[] {
    return this.db.prepare(sql).all(...params) as T[]
  }

  get<T = Record<string, unknown>>(sql: string, params: SqlParams = []): T | null {
    return (this.db.prepare(sql).get(...params) as T | undefined) ?? null
  }

  run(sql: string, params: SqlParams = []): { changes: number; lastInsertRowid: number | bigint } {
    const result = this.db.prepare(sql).run(...params)
    return { changes: Number(result.changes), lastInsertRowid: result.lastInsertRowid }
  }

  transaction<T>(fn: () => T): T {
    this.db.exec('BEGIN')
    try {
      const value = fn()
      this.db.exec('COMMIT')
      return value
    } catch (error) {
      this.db.exec('ROLLBACK')
      throw error
    }
  }
}

export function createLocalDb(path = process.env.SQLITE_PATH ?? 'data/meetings.sqlite'): LocalDb {
  if (path !== ':memory:') mkdirSync(dirname(path), { recursive: true })
  const db = new LocalDb(path)
  const root = dirname(dirname(dirname(fileURLToPath(import.meta.url))))
  db.exec(readFileSync(resolve(root, 'schema.sql'), 'utf8'))
  refreshSearchTerms(db)
  return db
}
