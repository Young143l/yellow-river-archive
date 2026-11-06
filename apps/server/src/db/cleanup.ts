/**
 * 清理孤儿同步数据。
 *
 * 来历：配对码时代（ADR-044 之前）身份是 `u_xxx`，由设备本地生成、
 * 没有账号表背书。配对码退役后，这些 id 名下的收藏/笔记/快照再也登不进去，
 * 留在库里既占空间，也会在答辩时被问「这些没有账号的数据是什么」。
 *
 * 默认只报告不删除，`--apply` 才动数据。
 * 用法：pnpm --filter @yra/server run cleanup
 *       pnpm --filter @yra/server run cleanup -- --apply
 */

import { readServerConfig } from '../config'
import { getDb, openDb, closeDb } from './index'
import type { Db } from './index'

interface TableStat {
  readonly table: string
  readonly orphans: number
  readonly total: number
}

const USER_TABLES: string[] = [
  'sync_records',
  'sync_changelog',
  'sync_conflicts',
  'sync_devices',
  'backup_snapshots',
]

function collect(db: Db): TableStat[] {
  const stats: TableStat[] = []
  for (const table of USER_TABLES) {
    const total = db.prepare(`SELECT COUNT(1) AS c FROM ${table}`).get() as unknown as { c: number }
    const orphans = db
      .prepare(
        `SELECT COUNT(1) AS c FROM ${table}
          WHERE user_id NOT IN (SELECT id FROM accounts)`
      )
      .get() as unknown as { c: number }
    stats.push({ table, orphans: orphans.c, total: total.c })
  }
  return stats
}

function main(): void {
  const apply: boolean = process.argv.includes('--apply')
  const cfg = readServerConfig()
  openDb(cfg.dbPath)
  const db = getDb()

  // 配对码表在 ADR-044 后已从 schema 移除，老库里的残留一并收掉
  const legacy = db
    .prepare(`SELECT COUNT(1) AS c FROM sqlite_master WHERE type = 'table' AND name = 'pairing_codes'`)
    .get() as unknown as { c: number }

  const stats: TableStat[] = collect(db)
  const orphanTotal: number = stats.reduce((s, x) => s + x.orphans, 0)

  console.log(`[cleanup] 库 ${cfg.dbPath}`)
  const accounts = db.prepare('SELECT COUNT(1) AS c FROM accounts').get() as unknown as { c: number }
  console.log(`[cleanup] 账号 ${accounts.c} 个`)
  for (const s of stats) {
    console.log(`  ${s.table.padEnd(18)} 共 ${s.total} 行，无账号归属 ${s.orphans} 行`)
  }
  console.log(`  pairing_codes      ${legacy.c > 0 ? '表仍存在' : '已不存在'}`)

  if (orphanTotal === 0 && legacy.c === 0) {
    console.log('[cleanup] 没有需要清理的数据')
    closeDb()
    return
  }

  if (!apply) {
    console.log(`[cleanup] 试运行：可删 ${orphanTotal} 行。加 --apply 执行`)
    closeDb()
    return
  }

  db.exec('BEGIN')
  try {
    for (const table of USER_TABLES) {
      db.prepare(`DELETE FROM ${table} WHERE user_id NOT IN (SELECT id FROM accounts)`).run()
    }
    db.exec('DROP TABLE IF EXISTS pairing_codes')
    db.exec('COMMIT')
  } catch (err) {
    db.exec('ROLLBACK')
    throw err
  }
  console.log(`[cleanup] 已删除 ${orphanTotal} 行孤儿数据，并移除 pairing_codes 表`)
  closeDb()
}

main()
