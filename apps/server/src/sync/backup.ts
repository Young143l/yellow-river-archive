/**
 * 云端快照（备份点）。
 *
 * 设计取舍：快照**不是另一份数据副本**，而是对 `sync_records` 的一次时间点复制。
 * 理由：
 *   1. 同步表已经是服务端的权威版本，快照只是给它打个时间戳标签
 *   2. 如果快照另存一套结构，两套结构一旦不同步就会出现「恢复出来的数据和当前不一致」
 *   3. 80 条档案的数据量在 KB 级，整份复制的成本可以忽略
 *
 * 恢复策略：不直接覆盖服务端数据，而是**把快照当成一批"远端变更"返回给客户端**，
 * 由客户端走既有的 LWW 合并路径落库。这样「恢复」「同步」「导入」三条路径共用
 * 同一套收敛逻辑，不会出现「恢复覆盖了更新的本地版本」这类反直觉行为。
 */

import type { BackupSnapshot, ChangeSet, SyncableRecord } from '@yra/shared'

import type { Db } from '../db/index'
import { SYNCABLE_TABLES } from '../db/schema'

export interface SnapshotResult {
  readonly ok: boolean
  readonly snapshot?: BackupSnapshot
  readonly message: string
}

/** 把某用户当前的记录打包成 ChangeSet 列表（快照与恢复共用） */
export function collectUserChanges(db: Db, userId: string): ChangeSet[] {
  const sets: ChangeSet[] = []
  for (const table of SYNCABLE_TABLES) {
    const rows = db
      .prepare(
        `SELECT payload FROM sync_records WHERE user_id = ? AND table_name = ? ORDER BY record_id ASC`
      )
      .all(userId, table) as unknown as { payload: string }[]
    const records: SyncableRecord[] = []
    for (const row of rows) {
      records.push(JSON.parse(row.payload) as SyncableRecord)
    }
    if (records.length > 0) {
      sets.push({ table, records })
    }
  }
  return sets
}

/** 创建快照 */
export function createSnapshot(db: Db, userId: string): SnapshotResult {
  const changes: ChangeSet[] = collectUserChanges(db, userId)
  let itemCount: number = 0
  for (const set of changes) {
    itemCount += set.records.length
  }

  if (itemCount === 0) {
    return { ok: false, message: '当前没有可备份的数据' }
  }

  const payload: string = JSON.stringify({ version: '1.0', exportedAt: Date.now(), changes })
  const sizeBytes: number = Buffer.byteLength(payload, 'utf8')
  const id: string = `snap_${Date.now().toString(36)}`
  const createdAt: number = Date.now()

  db.prepare(
    `INSERT INTO backup_snapshots (id, user_id, created_at, size_bytes, item_count, payload)
     VALUES (?, ?, ?, ?, ?, ?)`
  ).run(id, userId, createdAt, sizeBytes, itemCount, payload)

  return {
    ok: true,
    snapshot: { id, createdAt, sizeBytes, itemCount },
    message: `快照已保存：${itemCount} 条记录 / ${Math.round(sizeBytes / 1024)} KB`,
  }
}

/** 列出快照（不含内容，列表用） */
export function listSnapshots(db: Db, userId: string, limit: number): BackupSnapshot[] {
  const rows = db
    .prepare(
      `SELECT id, created_at AS createdAt, size_bytes AS sizeBytes, item_count AS itemCount
         FROM backup_snapshots WHERE user_id = ? ORDER BY created_at DESC LIMIT ?`
    )
    .all(userId, limit) as unknown as BackupSnapshot[]
  return rows
}

/**
 * 取快照内容用于恢复。
 *
 * **不直接写服务端数据** —— 返回 ChangeSet 让客户端走 LWW 合并。
 * 直接覆盖会让「恢复到旧快照」意外回退掉快照之后的所有改动，
 * 而用户点「恢复」时通常并不期望这个语义。
 */
export function readSnapshotForRestore(
  db: Db,
  userId: string,
  snapshotId: string
): { ok: boolean; changes: ChangeSet[]; message: string } {
  const row = db
    .prepare('SELECT payload FROM backup_snapshots WHERE user_id = ? AND id = ?')
    .get(userId, snapshotId) as { payload: string } | undefined

  if (row === undefined) {
    return { ok: false, changes: [], message: '快照不存在' }
  }

  try {
    const parsed = JSON.parse(row.payload) as { changes?: ChangeSet[] }
    const changes: ChangeSet[] = parsed.changes ?? []
    let count: number = 0
    for (const set of changes) {
      count += set.records.length
    }
    return { ok: true, changes, message: `快照含 ${count} 条记录，将按最新时间戳合并` }
  } catch (err) {
    return { ok: false, changes: [], message: '快照内容损坏' }
  }
}

/** 删除快照 */
export function deleteSnapshot(db: Db, userId: string, snapshotId: string): boolean {
  const result = db
    .prepare('DELETE FROM backup_snapshots WHERE user_id = ? AND id = ?')
    .run(userId, snapshotId)
  return Number(result.changes) > 0
}

/** 快照统计（管理页与自检用） */
export function snapshotStats(db: Db, userId: string): { count: number; totalBytes: number } {
  const row = db
    .prepare(
      'SELECT COUNT(*) AS count, COALESCE(SUM(size_bytes), 0) AS totalBytes FROM backup_snapshots WHERE user_id = ?'
    )
    .get(userId) as { count: number; totalBytes: number } | undefined
  return { count: row?.count ?? 0, totalBytes: row?.totalBytes ?? 0 }
}
