/**
 * 数据库连接。
 *
 * 用 Node 内置的 node:sqlite（ADR-023）：无原生依赖、无编译、自带 FTS5。
 * 同步 API —— 本地 SQLite 的读写是微秒级，异步包装只会增加复杂度。
 */

import { mkdirSync } from 'node:fs'
import { dirname } from 'node:path'
import { DatabaseSync } from 'node:sqlite'

import { SCHEMA_STATEMENTS } from './schema'

export type Db = DatabaseSync

let instance: DatabaseSync | undefined = undefined

/** 打开（并初始化）数据库，全局复用同一连接 */
export function openDb(path: string): DatabaseSync {
  if (instance !== undefined) {
    return instance
  }
  if (path !== ':memory:') {
    mkdirSync(dirname(path), { recursive: true })
  }
  const db: DatabaseSync = new DatabaseSync(path)
  // WAL 提升并发读性能；外键约束按需开启（图谱导入有依赖顺序）
  db.exec('PRAGMA journal_mode = WAL')
  db.exec('PRAGMA synchronous = NORMAL')
  for (const statement of SCHEMA_STATEMENTS) {
    db.exec(statement)
  }
  instance = db
  return db
}

export function getDb(): DatabaseSync {
  if (instance === undefined) {
    throw new Error('数据库尚未打开，请先调用 openDb')
  }
  return instance
}

export function closeDb(): void {
  if (instance !== undefined) {
    instance.close()
    instance = undefined
  }
}

/** 写 meta 键值 */
export function putMeta(db: DatabaseSync, key: string, value: string): void {
  db.prepare('INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)').run(key, value)
}

/** 读 meta 键值 */
export function getMeta(db: DatabaseSync, key: string): string | undefined {
  const row = db.prepare('SELECT value FROM meta WHERE key = ?').get(key) as
    | { value: string }
    | undefined
  return row?.value
}

/** 记录一次外部调用（成本可观测） */
export function logUsage(
  db: DatabaseSync,
  operation: string,
  tokens: number,
  elapsedMs: number,
  ok: boolean
): void {
  db.prepare(
    'INSERT INTO usage_log (operation, tokens, elapsed_ms, ok, created_at) VALUES (?, ?, ?, ?, ?)'
  ).run(operation, tokens, elapsedMs, ok ? 1 : 0, Date.now())
}

/** 汇总用量 */
export function summarizeUsage(
  db: DatabaseSync,
  since: number
): { operation: string; callCount: number; tokens: number; totalMs: number; errorCount: number }[] {
  return db
    .prepare(
      `SELECT operation,
              COUNT(*) AS callCount,
              SUM(tokens) AS tokens,
              SUM(elapsed_ms) AS totalMs,
              SUM(CASE WHEN ok = 0 THEN 1 ELSE 0 END) AS errorCount
         FROM usage_log
        WHERE created_at >= ?
        GROUP BY operation
        ORDER BY totalMs DESC`
    )
    .all(since) as { operation: string; callCount: number; tokens: number; totalMs: number; errorCount: number }[]
}
