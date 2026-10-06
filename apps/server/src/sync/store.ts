/**
 * 服务端同步存储。
 *
 * 这是 LWW 收敛逻辑的**第二实现** —— 端侧已有一份（PersonalDao.applyRemote）。
 * 两份独立实现互为参照：若协议理解有偏差，两端行为会出现分歧，比单份实现更容易暴露问题。
 *
 * 游标设计：用 `sync_changelog.seq`（自增单调序号）而不是时间戳。
 * 时间戳游标的经典漏拉场景是「客户端游标 T，新变更的服务器时间戳也是 T」，
 * `> T` 会永久跳过它。单调序号只在有变更时递增且严格可比较，没有这个窗口。
 */

import type {
  ChangeSet,
  ConflictRecord,
  SyncableRecord,
} from '@yra/shared'

import type { Db } from '../db/index'
import { SYNCABLE_TABLES } from '../db/schema'

export interface ApplyResult {
  readonly applied: number
  readonly skipped: number
  readonly conflicts: ConflictRecord[]
}

export interface PullResult {
  readonly changes: ChangeSet[]
  readonly cursor: number
  readonly conflicts: ConflictRecord[]
}

/** 服务端保存的一条记录 */
interface ServerRecord {
  readonly userId: string
  readonly tableName: string
  readonly recordId: string
  readonly updatedAt: number
  readonly createdAt: number
  readonly deviceId: string
  readonly deleted: boolean
  readonly payload: string
}

function readCursor(db: Db, userId: string): number {
  const row = db
    .prepare('SELECT COALESCE(MAX(seq), 0) AS m FROM sync_changelog WHERE user_id = ?')
    .get(userId) as { m: number } | undefined
  return row?.m ?? 0
}

function readRecord(
  db: Db,
  userId: string,
  table: string,
  recordId: string
): ServerRecord | undefined {
  const row = db
    .prepare(
      `SELECT user_id AS userId, table_name AS tableName, record_id AS recordId,
              updated_at AS updatedAt, created_at AS createdAt, device_id AS deviceId,
              deleted AS deletedRaw, payload
         FROM sync_records
        WHERE user_id = ? AND table_name = ? AND record_id = ?`
    )
    .get(userId, table, recordId) as
    | {
        userId: string
        tableName: string
        recordId: string
        updatedAt: number
        createdAt: number
        deviceId: string
        deletedRaw: number
        payload: string
      }
    | undefined

  if (row === undefined) {
    return undefined
  }
  return {
    userId: row.userId,
    tableName: row.tableName,
    recordId: row.recordId,
    updatedAt: row.updatedAt,
    createdAt: row.createdAt,
    deviceId: row.deviceId,
    deleted: row.deletedRaw === 1,
    payload: row.payload,
  }
}

/**
 * LWW 判定 —— 与端侧 `Types.ets` 的 remoteWins 必须是**同一条规则**。
 *
 * 时间戳相同时按 deviceId 字典序兜底。这条规则的关键是两端一致：
 * 若一端判「本地赢」另一端判「远端赢」，两端会永久分叉且每次同步各自再改一遍。
 */
export function incomingWins(local: ServerRecord | undefined, incoming: SyncableRecord): boolean {
  if (local === undefined) {
    return true
  }
  if (incoming.updatedAt !== local.updatedAt) {
    return incoming.updatedAt > local.updatedAt
  }
  return incoming.deviceId > local.deviceId
}

/** 写一条变更日志 */
function appendChangelog(
  db: Db,
  userId: string,
  table: string,
  recordId: string,
  deviceId: string,
  updatedAt: number
): void {
  db.prepare(
    `INSERT INTO sync_changelog (user_id, table_name, record_id, device_id, updated_at, created_at)
     VALUES (?, ?, ?, ?, ?, ?)`
  ).run(userId, table, recordId, deviceId, updatedAt, Date.now())
}

function logConflict(db: Db, userId: string, conflict: ConflictRecord): void {
  db.prepare(
    `INSERT OR REPLACE INTO sync_conflicts
       (id, user_id, record_id, table_name, local_updated_at, remote_updated_at, winner, detected_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)`
  ).run(
    conflict.id,
    userId,
    conflict.recordId,
    conflict.table,
    conflict.localUpdatedAt,
    conflict.remoteUpdatedAt,
    conflict.winner,
    conflict.detectedAt
  )
}

/**
 * 应用客户端推送的变更。
 *
 * 与端侧 applyRemote 对称：本地（此处的"本地"是服务端已存的版本）更新则保留、
 * 记冲突；远端（客户端）更新则覆盖。**只有服务端存的是权威版本，多设备才能收敛到一致。**
 */
export function applyPush(db: Db, userId: string, changes: readonly ChangeSet[]): ApplyResult {
  let applied: number = 0
  let skipped: number = 0
  const conflicts: ConflictRecord[] = []

  db.exec('BEGIN')
  try {
    for (const set of changes) {
      // 只接受已知表名，避免客户端用任意表名污染数据库
      if (!SYNCABLE_TABLES.includes(set.table)) {
        continue
      }
      for (const record of set.records) {
        const local: ServerRecord | undefined = readRecord(db, userId, set.table, record.id)

        if (!incomingWins(local, record)) {
          // 服务端存的更新：保留服务端版本，记一条冲突
          if (local !== undefined && local.updatedAt !== record.updatedAt) {
            const conflict: ConflictRecord = {
              id: `${set.table}:${record.id}:${local.updatedAt}:${record.deviceId}`,
              recordId: record.id,
              table: set.table,
              localUpdatedAt: local.updatedAt,
              remoteUpdatedAt: record.updatedAt,
              winner: 'local',
              detectedAt: Date.now(),
            }
            conflicts.push(conflict)
            logConflict(db, userId, conflict)
          }
          skipped += 1
          continue
        }

        // 完全同版本：跳过，且**不记变更日志**（否则每次重复推送都会产生新游标，
        // 对端会被无意义地唤醒）
        if (
          local !== undefined &&
          local.updatedAt === record.updatedAt &&
          local.deviceId === record.deviceId &&
          local.deleted === record.deleted
        ) {
          skipped += 1
          continue
        }

        if (local !== undefined) {
          const conflict: ConflictRecord = {
            id: `${set.table}:${record.id}:${local.updatedAt}:${record.deviceId}`,
            recordId: record.id,
            table: set.table,
            localUpdatedAt: local.updatedAt,
            remoteUpdatedAt: record.updatedAt,
            winner: 'remote',
            detectedAt: Date.now(),
          }
          conflicts.push(conflict)
          logConflict(db, userId, conflict)
        }

        db.prepare(
          `INSERT OR REPLACE INTO sync_records
             (user_id, table_name, record_id, updated_at, created_at, device_id, deleted, payload)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?)`
        ).run(
          userId,
          set.table,
          record.id,
          record.updatedAt,
          record.createdAt,
          record.deviceId,
          record.deleted ? 1 : 0,
          JSON.stringify(record)
        )
        appendChangelog(db, userId, set.table, record.id, record.deviceId, record.updatedAt)
        applied += 1
      }
    }
    db.exec('COMMIT')
  } catch (err) {
    db.exec('ROLLBACK')
    throw err
  }

  return { applied, skipped, conflicts }
}

/**
 * 拉取游标之后的变更。
 *
 * 按 seq 排序而非按记录去重：**同一个 record 可能在游标之后被改了两次**，
 * 两次都要出现在变更流里吗？不需要 —— 客户端只关心最终状态，
 * 所以对每个 record 只取它最新的那条变更（后出现的覆盖先出现的）。
 */
export function applyPull(
  db: Db,
  userId: string,
  since: number,
  excludeDeviceId: string
): PullResult {
  const rows = db
    .prepare(
      `SELECT seq, table_name AS tableName, record_id AS recordId
         FROM sync_changelog
        WHERE user_id = ? AND seq > ? AND device_id != ?
        ORDER BY seq ASC`
    )
    .all(userId, since, excludeDeviceId) as unknown as {
    seq: number
    tableName: string
    recordId: string
  }[]

  const cursor: number = rows.length > 0 ? (rows[rows.length - 1]?.seq ?? since) : readCursor(db, userId)

  // 同一记录多次变更只保留最后一次
  const latest = new Map<string, { table: string; recordId: string }>()
  for (const row of rows) {
    latest.set(`${row.tableName}:${row.recordId}`, { table: row.tableName, recordId: row.recordId })
  }

  const byTable = new Map<string, SyncableRecord[]>()
  for (const entry of latest.values()) {
    const rec: ServerRecord | undefined = readRecord(db, userId, entry.table, entry.recordId)
    if (rec === undefined) {
      continue
    }
    const list: SyncableRecord[] = byTable.get(entry.table) ?? []
    list.push(JSON.parse(rec.payload) as SyncableRecord)
    byTable.set(entry.table, list)
  }

  const changes: ChangeSet[] = []
  for (const [table, records] of byTable.entries()) {
    changes.push({ table, records })
  }

  const conflictRows = db
    .prepare(
      `SELECT id, record_id AS recordId, table_name AS tableName,
              local_updated_at AS localUpdatedAt, remote_updated_at AS remoteUpdatedAt,
              winner, detected_at AS detectedAt
         FROM sync_conflicts
        WHERE user_id = ?
        ORDER BY detected_at DESC
        LIMIT 50`
    )
    .all(userId) as unknown as {
    id: string
    recordId: string
    tableName: string
    localUpdatedAt: number
    remoteUpdatedAt: number
    winner: string
    detectedAt: number
  }[]

  const conflicts: ConflictRecord[] = conflictRows.map((row) => ({
    id: row.id,
    recordId: row.recordId,
    table: row.tableName,
    localUpdatedAt: row.localUpdatedAt,
    remoteUpdatedAt: row.remoteUpdatedAt,
    winner: row.winner === 'remote' ? 'remote' : 'local',
    detectedAt: row.detectedAt,
  }))

  return { changes, cursor, conflicts }
}

/** 当前游标（用于初始状态查询） */
export function currentCursor(db: Db, userId: string): number {
  return readCursor(db, userId)
}

/** 某用户的服务端记录统计（管理页与自检用） */
export function userStats(
  db: Db,
  userId: string
): { records: number; changelog: number; conflicts: number } {
  const one = (sql: string): number => {
    const row = db.prepare(sql).get(userId) as { n: number } | undefined
    return row?.n ?? 0
  }
  return {
    records: one('SELECT COUNT(*) AS n FROM sync_records WHERE user_id = ?'),
    changelog: one('SELECT COUNT(*) AS n FROM sync_changelog WHERE user_id = ?'),
    conflicts: one('SELECT COUNT(*) AS n FROM sync_conflicts WHERE user_id = ?'),
  }
}
