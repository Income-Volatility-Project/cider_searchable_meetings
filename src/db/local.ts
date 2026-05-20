import { mkdirSync, readFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { DatabaseSync } from 'node:sqlite'
import { refreshSearchTermsSync } from '../search_terms.ts'
import type { Db, RunResult, SqlParams } from './types.ts'

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

  run(sql: string, params: SqlParams = []): RunResult {
    const result = this.db.prepare(sql).run(...params)
    return { changes: Number(result.changes), lastInsertRowid: result.lastInsertRowid }
  }

  transaction<T>(fn: () => T | Promise<T>): T | Promise<T> {
    this.db.exec('BEGIN')
    let value: T | Promise<T>
    try {
      value = fn()
    } catch (error) {
      this.db.exec('ROLLBACK')
      throw error
    }

    if (isPromise(value)) {
      return value.then(
        (resolved) => {
          this.db.exec('COMMIT')
          return resolved
        },
        (error) => {
          this.db.exec('ROLLBACK')
          throw error
        },
      )
    }

    this.db.exec('COMMIT')
    return value
  }
}

export function createLocalDb(path = process.env.SQLITE_PATH ?? 'data/meetings.sqlite'): LocalDb {
  if (path !== ':memory:') mkdirSync(dirname(path), { recursive: true })
  const db = new LocalDb(path)
  const root = dirname(dirname(dirname(fileURLToPath(import.meta.url))))
  db.exec(readFileSync(resolve(root, 'schema.sql'), 'utf8'))
  refreshSearchTermsSync(db)
  return db
}

export type { Db, SqlParams } from './types.ts'

function isPromise<T>(value: T | Promise<T>): value is Promise<T> {
  return value !== null && typeof value === 'object' && typeof (value as Promise<T>).then === 'function'
}
