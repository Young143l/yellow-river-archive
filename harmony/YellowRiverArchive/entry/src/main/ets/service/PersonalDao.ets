/**
 * 个人数据访问层（收藏 / 笔记 / 标签 / 主题 / 已读）。
 *
 * 三条设计纪律：
 *
 * 1. **收藏与已读的 id 由目标确定性生成**（`site:ly-erlitou`），笔记与主题用随机
 *    id。前者若不这样做，两台设备各自收藏同一条目会产生两条记录，LWW 无从收敛，
 *    用户看到重复项；后者同一目标允许多条，本就不该合并。
 *
 * 2. **删除一律软删**（deleted=1）。硬删会让对端推送的旧版本把记录"复活"。
 *
 * 3. **待推送集由时间戳推导**（updated_at > lastPushedAt），不另建队列表。
 *    队列表要与数据表保持同步，漏更新就会出现"永远推不完"或"改了没推"的隐形 bug。
 */

import { util } from '@kit.ArkTS'
import { fileIo } from '@kit.CoreFileKit'
import { relationalStore } from '@kit.ArkData'
import { common } from '@kit.AbilityKit'

import type {
  BackupPayload,
  ChangeSet,
  CollectTargetType,
  ConflictRecord,
  CountPair,
  Favorite,
  ImportResult,
  Theme,
  Note,
  Progress,
  SyncableRecord,
  Tag,
} from '../shared'
import { Tables, SyncKeys } from '../model/Schema'
import { DataImportService } from './DataImportService'
import { isSameVersion, remoteWins, toEnvelope, type SyncEnvelope } from './sync/Types'

/** 收藏目标的确定性 id */
export function favoriteId(targetType: string, targetId: string): string {
  return `${targetType}:${targetId}`
}

/** 应用远端变更的结果 */
export interface ApplyReport {
  readonly applied: number
  readonly skipped: number
  readonly conflicts: ConflictRecord[]
}

/** 由 LWW 元数据 + 各表内容拼出的可同步记录（用于推送） */
interface RawRow {
  readonly id: string
  readonly updatedAt: number
  readonly createdAt: number
  readonly deviceId: string
  readonly deleted: boolean
}

function nowMs(): number {
  return new Date().getTime()
}

function newId(): string {
  return util.generateRandomUUID(true)
}

/** 通用：从结果集读一行 LWW 元数据 */
function readEnvelope(rs: relationalStore.ResultSet): SyncEnvelope {
  return {
    id: rs.getString(rs.getColumnIndex('id')),
    updatedAt: rs.getLong(rs.getColumnIndex('updated_at')),
    createdAt: rs.getLong(rs.getColumnIndex('created_at')),
    deviceId: rs.getString(rs.getColumnIndex('device_id')),
    deleted: rs.getLong(rs.getColumnIndex('deleted')) === 1,
  }
}

function readRawRow(rs: relationalStore.ResultSet): RawRow {
  const env: SyncEnvelope = readEnvelope(rs)
  return {
    id: env.id,
    updatedAt: env.updatedAt,
    createdAt: env.createdAt,
    deviceId: env.deviceId,
    deleted: env.deleted,
  }
}

export class PersonalDao {
  private static deviceId: string = ''

  /**
   * 本机设备标识。
   *
   * 自己生成并持久化，不用系统 ODID：ODID 在不同账号/重置后会变，
   * 而 LWW 的兜底比较依赖它**稳定**，否则同一条记录在不同时刻的比较结果会翻转。
   */
  static async getDeviceId(context: common.Context): Promise<string> {
    if (PersonalDao.deviceId.length > 0) {
      return PersonalDao.deviceId
    }
    const stored: string = await PersonalDao.getSyncMeta(context, SyncKeys.DEVICE_ID)
    if (stored.length > 0) {
      PersonalDao.deviceId = stored
      return stored
    }
    const created: string = newId()
    await PersonalDao.setSyncMeta(context, SyncKeys.DEVICE_ID, created)
    PersonalDao.deviceId = created
    return created
  }

  // -------------------------------------------------------------------------
  // 同步元数据
  // -------------------------------------------------------------------------

  static async getSyncMeta(context: common.Context, key: string): Promise<string> {
    const store: relationalStore.RdbStore = await DataImportService.open(context)
    const rs: relationalStore.ResultSet = await store.querySql(
      `SELECT value FROM ${Tables.SYNC_META} WHERE key = ?`,
      [key]
    )
    let value: string = ''
    if (rs.goToNextRow()) {
      value = rs.getString(0)
    }
    rs.close()
    return value
  }

  static async setSyncMeta(context: common.Context, key: string, value: string): Promise<void> {
    const store: relationalStore.RdbStore = await DataImportService.open(context)
    await store.executeSql(
      `INSERT OR REPLACE INTO ${Tables.SYNC_META} (key, value) VALUES (?, ?)`,
      [key, value]
    )
  }

  // -------------------------------------------------------------------------
  // 已读（学习进度）
  // -------------------------------------------------------------------------

  static async recordVisit(context: common.Context, itemId: string): Promise<void> {
    const store: relationalStore.RdbStore = await DataImportService.open(context)
    const deviceId: string = await PersonalDao.getDeviceId(context)
    const now: number = nowMs()
    // 已读过就不刷新时间戳：否则每次打开详情页都算一次「变更」，
    // 待推送集永远清不空，同步中心会一直显示一堆待办
    await store.executeSql(
      `INSERT INTO ${Tables.VISITS} (item_id, visited_at, updated_at, created_at, device_id, deleted)
       VALUES (?, ?, ?, ?, ?, 0)
       ON CONFLICT(item_id) DO NOTHING`,
      [itemId, now, now, now, deviceId]
    )
  }

  static async visitedIds(context: common.Context): Promise<Set<string>> {
    const store: relationalStore.RdbStore = await DataImportService.open(context)
    const rs: relationalStore.ResultSet = await store.querySql(
      `SELECT item_id FROM ${Tables.VISITS} WHERE deleted = 0`
    )
    const ids: Set<string> = new Set<string>()
    while (rs.goToNextRow()) {
      ids.add(rs.getString(0))
    }
    rs.close()
    return ids
  }

  /** 按时代统计已读/总数（时间轴与我的档案页用） */
  static async progressByEra(context: common.Context, eraOrder: string[]): Promise<Progress[]> {
    const store: relationalStore.RdbStore = await DataImportService.open(context)
    const visits: Set<string> = await PersonalDao.visitedIds(context)

    const totals: Map<string, number> = new Map<string, number>()
    const visited: Map<string, number> = new Map<string, number>()
    for (const era of eraOrder) {
      totals.set(era, 0)
      visited.set(era, 0)
    }

    const rs: relationalStore.ResultSet = await store.querySql(
      `SELECT id, era FROM ${Tables.ITEMS}`
    )
    while (rs.goToNextRow()) {
      const id: string = rs.getString(0)
      const era: string = rs.getString(1)
      if (!totals.has(era)) {
        continue
      }
      totals.set(era, (totals.get(era) ?? 0) + 1)
      if (visits.has(id)) {
        visited.set(era, (visited.get(era) ?? 0) + 1)
      }
    }
    rs.close()

    const result: Progress[] = []
    for (const era of eraOrder) {
      result.push({
        era,
        visited: visited.get(era) ?? 0,
        total: totals.get(era) ?? 0,
      })
    }
    return result
  }

  /** 总进度：已读条目数 / 条目总数 */
  static async overallProgress(context: common.Context): Promise<CountPair> {
    const store: relationalStore.RdbStore = await DataImportService.open(context)
    const visitedCount: number = (await PersonalDao.visitedIds(context)).size
    const rs: relationalStore.ResultSet = await store.querySql(
      `SELECT COUNT(*) FROM ${Tables.ITEMS}`
    )
    let total: number = 0
    if (rs.goToNextRow()) {
      total = rs.getLong(0)
    }
    rs.close()
    return { done: visitedCount, total }
  }

  // -------------------------------------------------------------------------
  // 收藏
  // -------------------------------------------------------------------------

  /** 切换收藏状态，返回切换后的状态（true = 已收藏） */
  static async toggleFavorite(
    context: common.Context,
    targetType: string,
    targetId: string
  ): Promise<boolean> {
    const store: relationalStore.RdbStore = await DataImportService.open(context)
    const deviceId: string = await PersonalDao.getDeviceId(context)
    const id: string = favoriteId(targetType, targetId)
    const now: number = nowMs()

    const current: SyncEnvelope | undefined = await PersonalDao.readEnvelope(
      context,
      Tables.FAVORITES,
      id
    )
    const nextDeleted: boolean = current === undefined ? false : !current.deleted

    // 用 upsert 而不是先删后插：软删除要保留 created_at，
    // 且每次操作都要更新 updated_at 才能被 LWW 正确比较
    await store.executeSql(
      `INSERT INTO ${Tables.FAVORITES} (id, target_type, target_id, tag_ids, updated_at, created_at, device_id, deleted)
       VALUES (?, ?, ?, '[]', ?, ?, ?, ?)
       ON CONFLICT(id) DO UPDATE SET updated_at = ?, device_id = ?, deleted = ?`,
      [id, targetType, targetId, now, current === undefined ? now : current.createdAt, deviceId, nextDeleted ? 1 : 0, now, deviceId, nextDeleted ? 1 : 0]
    )

    return !nextDeleted
  }

  static async isFavorite(
    context: common.Context,
    targetType: string,
    targetId: string
  ): Promise<boolean> {
    const env: SyncEnvelope | undefined = await PersonalDao.readEnvelope(
      context,
      Tables.FAVORITES,
      favoriteId(targetType, targetId)
    )
    return env !== undefined && !env.deleted
  }

  static async listFavorites(context: common.Context): Promise<Favorite[]> {
    const store: relationalStore.RdbStore = await DataImportService.open(context)
    const rs: relationalStore.ResultSet = await store.querySql(
      `SELECT id, target_type, target_id, tag_ids, updated_at, created_at, device_id, deleted
         FROM ${Tables.FAVORITES} WHERE deleted = 0 ORDER BY created_at DESC`
    )
    const list: Favorite[] = []
    while (rs.goToNextRow()) {
      const tagIdsText: string = rs.getString(rs.getColumnIndex('tag_ids'))
      list.push({
        id: rs.getString(rs.getColumnIndex('id')),
        targetType: rs.getString(rs.getColumnIndex('target_type')) as CollectTargetType,
        targetId: rs.getString(rs.getColumnIndex('target_id')),
        tagIds: PersonalDao.parseStringArray(tagIdsText),
        updatedAt: rs.getLong(rs.getColumnIndex('updated_at')),
        createdAt: rs.getLong(rs.getColumnIndex('created_at')),
        deviceId: rs.getString(rs.getColumnIndex('device_id')),
        deleted: false,
      })
    }
    rs.close()
    return list
  }

  static async favoriteCount(context: common.Context): Promise<number> {
    const store: relationalStore.RdbStore = await DataImportService.open(context)
    const rs: relationalStore.ResultSet = await store.querySql(
      `SELECT COUNT(*) FROM ${Tables.FAVORITES} WHERE deleted = 0`
    )
    let n: number = 0
    if (rs.goToNextRow()) {
      n = rs.getLong(0)
    }
    rs.close()
    return n
  }

  // -------------------------------------------------------------------------
  // 笔记
  // -------------------------------------------------------------------------

  static async addNote(
    context: common.Context,
    targetType: string,
    targetId: string,
    content: string
  ): Promise<string> {
    const store: relationalStore.RdbStore = await DataImportService.open(context)
    const deviceId: string = await PersonalDao.getDeviceId(context)
    const id: string = newId()
    const now: number = nowMs()
    await store.executeSql(
      `INSERT INTO ${Tables.NOTES} (id, target_type, target_id, content, updated_at, created_at, device_id, deleted)
       VALUES (?, ?, ?, ?, ?, ?, ?, 0)`,
      [id, targetType, targetId, content, now, now, deviceId]
    )
    return id
  }

  static async updateNote(context: common.Context, id: string, content: string): Promise<void> {
    const store: relationalStore.RdbStore = await DataImportService.open(context)
    const deviceId: string = await PersonalDao.getDeviceId(context)
    await store.executeSql(
      `UPDATE ${Tables.NOTES} SET content = ?, updated_at = ?, device_id = ? WHERE id = ?`,
      [content, nowMs(), deviceId, id]
    )
  }

  /** 软删除笔记 */
  static async deleteNote(context: common.Context, id: string): Promise<void> {
    const store: relationalStore.RdbStore = await DataImportService.open(context)
    const deviceId: string = await PersonalDao.getDeviceId(context)
    await store.executeSql(
      `UPDATE ${Tables.NOTES} SET deleted = 1, updated_at = ?, device_id = ? WHERE id = ?`,
      [nowMs(), deviceId, id]
    )
  }

  /** 列出笔记；传 targetId 则只列该目标的（详情页用） */
  static async listNotes(context: common.Context, targetId: string = ''): Promise<Note[]> {
    const store: relationalStore.RdbStore = await DataImportService.open(context)
    const sql: string =
      targetId.length > 0
        ? `SELECT id, target_type, target_id, content, updated_at, created_at, device_id, deleted
             FROM ${Tables.NOTES} WHERE deleted = 0 AND target_id = ? ORDER BY updated_at DESC`
        : `SELECT id, target_type, target_id, content, updated_at, created_at, device_id, deleted
             FROM ${Tables.NOTES} WHERE deleted = 0 ORDER BY updated_at DESC`
    const args: string[] = targetId.length > 0 ? [targetId] : []
    const rs: relationalStore.ResultSet = await store.querySql(sql, args)

    const list: Note[] = []
    while (rs.goToNextRow()) {
      list.push({
        id: rs.getString(rs.getColumnIndex('id')),
        targetType: rs.getString(rs.getColumnIndex('target_type')) as CollectTargetType,
        targetId: rs.getString(rs.getColumnIndex('target_id')),
        content: rs.getString(rs.getColumnIndex('content')),
        updatedAt: rs.getLong(rs.getColumnIndex('updated_at')),
        createdAt: rs.getLong(rs.getColumnIndex('created_at')),
        deviceId: rs.getString(rs.getColumnIndex('device_id')),
        deleted: false,
      })
    }
    rs.close()
    return list
  }

  static async noteCount(context: common.Context): Promise<number> {
    const store: relationalStore.RdbStore = await DataImportService.open(context)
    const rs: relationalStore.ResultSet = await store.querySql(
      `SELECT COUNT(*) FROM ${Tables.NOTES} WHERE deleted = 0`
    )
    let n: number = 0
    if (rs.goToNextRow()) {
      n = rs.getLong(0)
    }
    rs.close()
    return n
  }

  // -------------------------------------------------------------------------
  // 标签
  // -------------------------------------------------------------------------

  static async listTags(context: common.Context): Promise<Tag[]> {
    const store: relationalStore.RdbStore = await DataImportService.open(context)
    const rs: relationalStore.ResultSet = await store.querySql(
      `SELECT id, name, preset, updated_at, created_at, device_id, deleted
         FROM ${Tables.TAGS} WHERE deleted = 0 ORDER BY preset DESC, name ASC`
    )
    const list: Tag[] = []
    while (rs.goToNextRow()) {
      list.push({
        id: rs.getString(rs.getColumnIndex('id')),
        name: rs.getString(rs.getColumnIndex('name')),
        preset: rs.getLong(rs.getColumnIndex('preset')) === 1,
        updatedAt: rs.getLong(rs.getColumnIndex('updated_at')),
        createdAt: rs.getLong(rs.getColumnIndex('created_at')),
        deviceId: rs.getString(rs.getColumnIndex('device_id')),
        deleted: false,
      })
    }
    rs.close()
    return list
  }

  static async createTag(context: common.Context, name: string): Promise<string> {
    const store: relationalStore.RdbStore = await DataImportService.open(context)
    const deviceId: string = await PersonalDao.getDeviceId(context)
    const id: string = newId()
    const now: number = nowMs()
    await store.executeSql(
      `INSERT INTO ${Tables.TAGS} (id, name, preset, updated_at, created_at, device_id, deleted)
       VALUES (?, ?, 0, ?, ?, ?, 0)`,
      [id, name, now, now, deviceId]
    )
    return id
  }

  // -------------------------------------------------------------------------
  // 同步支撑
  // -------------------------------------------------------------------------

  private static async readEnvelope(
    context: common.Context,
    table: string,
    id: string
  ): Promise<SyncEnvelope | undefined> {
    const store: relationalStore.RdbStore = await DataImportService.open(context)
    const rs: relationalStore.ResultSet = await store.querySql(
      `SELECT id, updated_at, created_at, device_id, deleted FROM ${table} WHERE id = ?`,
      [id]
    )
    let env: SyncEnvelope | undefined = undefined
    if (rs.goToNextRow()) {
      env = readEnvelope(rs)
    }
    rs.close()
    return env
  }

  /** 待推送条数（由时间戳推导，见文件头注释） */
  static async pendingCount(context: common.Context): Promise<number> {
    const since: string = await PersonalDao.getSyncMeta(context, SyncKeys.LAST_PUSHED_AT)
    const cursor: number = since.length > 0 ? Number.parseInt(since, 10) : 0
    const store: relationalStore.RdbStore = await DataImportService.open(context)

    let total: number = 0
    for (const table of ['tags', 'favorites', 'notes', 'themes', 'visits']) {
      const rs: relationalStore.ResultSet = await store.querySql(
        `SELECT COUNT(*) FROM ${table} WHERE updated_at > ?`,
        [cursor]
      )
      if (rs.goToNextRow()) {
        total += rs.getLong(0)
      }
      rs.close()
    }
    return total
  }

  /** 收集游标之后的本机变更，用于推送 */
  static async collectChanges(context: common.Context, since: number): Promise<ChangeSet[]> {
    const store: relationalStore.RdbStore = await DataImportService.open(context)
    const sets: ChangeSet[] = []

    const favoritesRs: relationalStore.ResultSet = await store.querySql(
      `SELECT id, target_type, target_id, tag_ids, updated_at, created_at, device_id, deleted
         FROM ${Tables.FAVORITES} WHERE updated_at > ?`,
      [`${since}`]
    )
    const favorites: SyncableRecord[] = []
    while (favoritesRs.goToNextRow()) {
      const env: SyncEnvelope = readEnvelope(favoritesRs)
      const rec: Favorite = {
        id: env.id,
        targetType: favoritesRs.getString(favoritesRs.getColumnIndex('target_type')) as CollectTargetType,
        targetId: favoritesRs.getString(favoritesRs.getColumnIndex('target_id')),
        tagIds: PersonalDao.parseStringArray(favoritesRs.getString(favoritesRs.getColumnIndex('tag_ids'))),
        updatedAt: env.updatedAt,
        createdAt: env.createdAt,
        deviceId: env.deviceId,
        deleted: env.deleted,
      }
      favorites.push(rec)
    }
    favoritesRs.close()
    if (favorites.length > 0) {
      sets.push({ table: Tables.FAVORITES, records: favorites })
    }

    const notesRs: relationalStore.ResultSet = await store.querySql(
      `SELECT id, target_type, target_id, content, updated_at, created_at, device_id, deleted
         FROM ${Tables.NOTES} WHERE updated_at > ?`,
      [`${since}`]
    )
    const notes: SyncableRecord[] = []
    while (notesRs.goToNextRow()) {
      const env: SyncEnvelope = readEnvelope(notesRs)
      const rec: Note = {
        id: env.id,
        targetType: notesRs.getString(notesRs.getColumnIndex('target_type')) as CollectTargetType,
        targetId: notesRs.getString(notesRs.getColumnIndex('target_id')),
        content: notesRs.getString(notesRs.getColumnIndex('content')),
        updatedAt: env.updatedAt,
        createdAt: env.createdAt,
        deviceId: env.deviceId,
        deleted: env.deleted,
      }
      notes.push(rec)
    }
    notesRs.close()
    if (notes.length > 0) {
      sets.push({ table: Tables.NOTES, records: notes })
    }

    const tagsRs: relationalStore.ResultSet = await store.querySql(
      `SELECT id, name, preset, updated_at, created_at, device_id, deleted
         FROM ${Tables.TAGS} WHERE updated_at > ?`,
      [`${since}`]
    )
    const tags: SyncableRecord[] = []
    while (tagsRs.goToNextRow()) {
      const env: SyncEnvelope = readEnvelope(tagsRs)
      const rec: Tag = {
        id: env.id,
        name: tagsRs.getString(tagsRs.getColumnIndex('name')),
        preset: tagsRs.getLong(tagsRs.getColumnIndex('preset')) === 1,
        updatedAt: env.updatedAt,
        createdAt: env.createdAt,
        deviceId: env.deviceId,
        deleted: env.deleted,
      }
      tags.push(rec)
    }
    tagsRs.close()
    if (tags.length > 0) {
      sets.push({ table: Tables.TAGS, records: tags })
    }

    const visitsRs: relationalStore.ResultSet = await store.querySql(
      `SELECT item_id, updated_at, created_at, device_id, deleted
         FROM ${Tables.VISITS} WHERE updated_at > ?`,
      [`${since}`]
    )
    const visits: SyncableRecord[] = []
    while (visitsRs.goToNextRow()) {
      // visits 的 id 就是 item_id（主键归一，避免两套标识）
      const id: string = visitsRs.getString(visitsRs.getColumnIndex('item_id'))
      visits.push({
        id,
        updatedAt: visitsRs.getLong(visitsRs.getColumnIndex('updated_at')),
        createdAt: visitsRs.getLong(visitsRs.getColumnIndex('created_at')),
        deviceId: visitsRs.getString(visitsRs.getColumnIndex('device_id')),
        deleted: visitsRs.getLong(visitsRs.getColumnIndex('deleted')) === 1,
      })
    }
    visitsRs.close()
    if (visits.length > 0) {
      sets.push({ table: Tables.VISITS, records: visits })
    }

    return sets
  }

  /**
   * 应用远端变更，按 LWW 收敛。
   *
   * 冲突判定：本地更新 → 本地赢（记冲突日志，不改数据）
   *          远端更新 → 远端赢（覆盖本地）
   *          时间相同 → deviceId 字典序大者赢（两端规则一致，保证收敛）
   */
  static async applyRemote(context: common.Context, sets: ChangeSet[]): Promise<ApplyReport> {
    const store: relationalStore.RdbStore = await DataImportService.open(context)
    let applied: number = 0
    let skipped: number = 0
    const conflicts: ConflictRecord[] = []

    for (const set of sets) {
      for (const record of set.records) {
        const remote: SyncEnvelope = toEnvelope(record)
        const local: SyncEnvelope | undefined = await PersonalDao.readEnvelopeById(
          store,
          set.table,
          remote.id
        )

        if (local !== undefined && !isSameVersion(local, remote) && !remoteWins(local, remote)) {
          // 本地更新：保留本地，记一条冲突以便在同步中心展示
          const conflict: ConflictRecord = {
            id: `${set.table}:${remote.id}:${remote.updatedAt}`,
            recordId: remote.id,
            table: set.table,
            localUpdatedAt: local.updatedAt,
            remoteUpdatedAt: remote.updatedAt,
            winner: 'local',
            detectedAt: nowMs(),
          }
          conflicts.push(conflict)
          await PersonalDao.logConflict(store, conflict)
          skipped += 1
          continue
        }

        if (local !== undefined && isSameVersion(local, remote)) {
          skipped += 1
          continue
        }

        if (local !== undefined && !remoteWins(local, remote)) {
          skipped += 1
          continue
        }

        // 远端更新（或本地不存在）：远端赢
        if (local !== undefined) {
          const conflict: ConflictRecord = {
            id: `${set.table}:${remote.id}:${local.updatedAt}`,
            recordId: remote.id,
            table: set.table,
            localUpdatedAt: local.updatedAt,
            remoteUpdatedAt: remote.updatedAt,
            winner: 'remote',
            detectedAt: nowMs(),
          }
          conflicts.push(conflict)
          await PersonalDao.logConflict(store, conflict)
        }
        await PersonalDao.writeRemote(store, set.table, record)
        applied += 1      }
    }

    return { applied, skipped, conflicts }
  }

  private static async readEnvelopeById(
    store: relationalStore.RdbStore,
    table: string,
    id: string
  ): Promise<SyncEnvelope | undefined> {
    const idColumn: string = table === Tables.VISITS ? 'item_id' : 'id'
    const rs: relationalStore.ResultSet = await store.querySql(
      `SELECT ${idColumn}, updated_at, created_at, device_id, deleted FROM ${table} WHERE ${idColumn} = ?`,
      [id]
    )
    let env: SyncEnvelope | undefined = undefined
    if (rs.goToNextRow()) {
      env = {
        id: rs.getString(0),
        updatedAt: rs.getLong(1),
        createdAt: rs.getLong(2),
        deviceId: rs.getString(3),
        deleted: rs.getLong(4) === 1,
      }
    }
    rs.close()
    return env
  }

  /**
   * 把一条远端记录写进本地表（保留远端的时间戳与 deviceId）。
   *
   * 用子类型下转而不是 `as Record<string, Object>`：后者在 ArkTS 里是非法转换
   * （两类无重叠），而 Favorite/Note/Tag 本就是 SyncableRecord 的子类型，
   * 下转既合法又保留了字段类型检查。
   */
  private static async writeRemote(
    store: relationalStore.RdbStore,
    table: string,
    record: SyncableRecord
  ): Promise<void> {
    if (table === Tables.FAVORITES) {
      await PersonalDao.writeFavorite(store, record as Favorite)
      return
    }
    if (table === Tables.NOTES) {
      await PersonalDao.writeNote(store, record as Note)
      return
    }
    if (table === Tables.TAGS) {
      await PersonalDao.writeTag(store, record as Tag)
      return
    }
    if (table === Tables.VISITS) {
      await PersonalDao.writeVisit(store, record)
    }
  }

  private static async writeFavorite(store: relationalStore.RdbStore, rec: Favorite): Promise<void> {
    await store.executeSql(
      `INSERT OR REPLACE INTO ${Tables.FAVORITES}
         (id, target_type, target_id, tag_ids, updated_at, created_at, device_id, deleted)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
      [
        rec.id,
        rec.targetType as string,
        rec.targetId,
        JSON.stringify(rec.tagIds),
        rec.updatedAt,
        rec.createdAt,
        rec.deviceId,
        rec.deleted ? 1 : 0,
      ]
    )
  }

  private static async writeNote(store: relationalStore.RdbStore, rec: Note): Promise<void> {
    await store.executeSql(
      `INSERT OR REPLACE INTO ${Tables.NOTES}
         (id, target_type, target_id, content, updated_at, created_at, device_id, deleted)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
      [
        rec.id,
        rec.targetType as string,
        rec.targetId,
        rec.content,
        rec.updatedAt,
        rec.createdAt,
        rec.deviceId,
        rec.deleted ? 1 : 0,
      ]
    )
  }

  private static async writeTag(store: relationalStore.RdbStore, rec: Tag): Promise<void> {
    await store.executeSql(
      `INSERT OR REPLACE INTO ${Tables.TAGS}
         (id, name, preset, updated_at, created_at, device_id, deleted)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
      [
        rec.id,
        rec.name,
        rec.preset ? 1 : 0,
        rec.updatedAt,
        rec.createdAt,
        rec.deviceId,
        rec.deleted ? 1 : 0,
      ]
    )
  }

  private static async writeVisit(
    store: relationalStore.RdbStore,
    rec: SyncableRecord
  ): Promise<void> {
    await store.executeSql(
      `INSERT OR REPLACE INTO ${Tables.VISITS}
         (item_id, visited_at, updated_at, created_at, device_id, deleted)
       VALUES (?, ?, ?, ?, ?, ?)`,
      [rec.id, rec.updatedAt, rec.updatedAt, rec.createdAt, rec.deviceId, rec.deleted ? 1 : 0]
    )
  }

  private static async logConflict(
    store: relationalStore.RdbStore,
    conflict: ConflictRecord
  ): Promise<void> {
    await store.executeSql(
      `INSERT OR REPLACE INTO ${Tables.CONFLICTS}
         (id, record_id, table_name, local_updated_at, remote_updated_at, winner, detected_at)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
      [
        conflict.id,
        conflict.recordId,
        conflict.table,
        conflict.localUpdatedAt,
        conflict.remoteUpdatedAt,
        conflict.winner,
        conflict.detectedAt,
      ]
    )
  }

  /** 最近的冲突记录（同步中心展示） */
  static async listConflicts(context: common.Context, limit: number = 20): Promise<ConflictRecord[]> {
    const store: relationalStore.RdbStore = await DataImportService.open(context)
    const rs: relationalStore.ResultSet = await store.querySql(
      `SELECT id, record_id, table_name, local_updated_at, remote_updated_at, winner, detected_at
         FROM ${Tables.CONFLICTS} ORDER BY detected_at DESC LIMIT ?`,
      [`${limit}`]
    )
    const list: ConflictRecord[] = []
    while (rs.goToNextRow()) {
      list.push({
        id: rs.getString(0),
        recordId: rs.getString(1),
        table: rs.getString(2),
        localUpdatedAt: rs.getLong(3),
        remoteUpdatedAt: rs.getLong(4),
        winner: rs.getString(5) === 'remote' ? 'remote' : 'local',
        detectedAt: rs.getLong(6),
      })
    }
    rs.close()
    return list
  }

  static async conflictCount(context: common.Context): Promise<number> {
    const store: relationalStore.RdbStore = await DataImportService.open(context)
    const rs: relationalStore.ResultSet = await store.querySql(
      `SELECT COUNT(*) FROM ${Tables.CONFLICTS}`
    )
    let n: number = 0
    if (rs.goToNextRow()) {
      n = rs.getLong(0)
    }
    rs.close()
    return n
  }

  // -------------------------------------------------------------------------
  // 备份与恢复（D4-10）
  // -------------------------------------------------------------------------

  /** 备份文件路径（应用沙箱内，卸载即清） */
  static backupPath(context: common.Context): string {
    return `${context.filesDir}/yra-backup.json`
  }

  /**
   * 全量导出。
   *
   * 导出的是**完整记录**（含 updatedAt / deviceId / deleted 三个 LWW 元数据），
   * 不是「当前有效数据」—— 少了元数据，导入时就无法判断该保留哪一份，
   * 只能整份覆盖，那会丢掉导入之后产生的更新。
   */
  static async exportBackup(context: common.Context): Promise<BackupPayload> {
    const favorites: Favorite[] = await PersonalDao.listFavorites(context)
    const notes: Note[] = await PersonalDao.listNotes(context)
    const tags: Tag[] = await PersonalDao.listTags(context)
    const themes: Theme[] = await PersonalDao.listThemes(context)
    const deviceId: string = await PersonalDao.getDeviceId(context)

    return {
      version: '1.0',
      exportedAt: new Date().getTime(),
      deviceId,
      favorites,
      notes,
      tags,
      themes,
    }
  }

  /** 导出到沙箱文件，返回文件路径与字节数 */
  static async exportToFile(context: common.Context): Promise<string> {
    const payload: BackupPayload = await PersonalDao.exportBackup(context)
    const text: string = JSON.stringify(payload)
    const path: string = PersonalDao.backupPath(context)
    const file = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC)
    try {
      fileIo.writeSync(file.fd, text)
    } finally {
      fileIo.closeSync(file)
    }
    return path
  }

  /** 读取沙箱备份文件的原始文本（不存在返回空串） */
  static readBackupFile(context: common.Context): string {
    const path: string = PersonalDao.backupPath(context)
    if (!fileIo.accessSync(path)) {
      return ''
    }
    const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY)
    try {
      const stat = fileIo.statSync(path)
      const buffer = new ArrayBuffer(stat.size)
      fileIo.readSync(file.fd, buffer)
      const decoder = util.TextDecoder.create('utf-8')
      return decoder.decodeToString(new Uint8Array(buffer))
    } finally {
      fileIo.closeSync(file)
    }
  }

  /**
   * 导入合并。
   *
   * **复用 applyRemote 的 LWW 逻辑**，不另写一套合并：
   * 备份载荷先转成 ChangeSet，再走与同步完全相同的收敛路径。
   * 这样「导入」「同步」「云端快照恢复」三条路径的行为天然一致 ——
   * 不会出现「导入会覆盖、恢复不会」这种让人记不住的差异。
   */
  static async importBackup(context: common.Context, payload: BackupPayload): Promise<ImportResult> {
    const sets: ChangeSet[] = []
    if (payload.favorites.length > 0) {
      sets.push({ table: 'favorites', records: payload.favorites })
    }
    if (payload.notes.length > 0) {
      sets.push({ table: 'notes', records: payload.notes })
    }
    if (payload.tags.length > 0) {
      sets.push({ table: 'tags', records: payload.tags })
    }
    if (payload.themes.length > 0) {
      sets.push({ table: 'themes', records: payload.themes })
    }

    const report = await PersonalDao.applyRemote(context, sets)
    return {
      imported: report.applied,
      merged: report.skipped,
      conflicts: report.conflicts,
    }
  }

  /** 从沙箱文件导入 */
  static async importFromFile(context: common.Context): Promise<ImportResult> {
    const text: string = PersonalDao.readBackupFile(context)
    if (text.length === 0) {
      return { imported: 0, merged: 0, conflicts: [] }
    }
    const payload = JSON.parse(text) as BackupPayload
    return PersonalDao.importBackup(context, payload)
  }

  /** 列出主题（备份载荷与文档视图都要用） */
  static async listThemes(context: common.Context): Promise<Theme[]> {
    const store: relationalStore.RdbStore = await DataImportService.open(context)
    const rs: relationalStore.ResultSet = await store.querySql(
      `SELECT id, name, target_ids, updated_at, created_at, device_id, deleted
         FROM ${Tables.THEMES} WHERE deleted = 0 ORDER BY updated_at DESC`
    )
    const list: Theme[] = []
    while (rs.goToNextRow()) {
      list.push({
        id: rs.getString(rs.getColumnIndex('id')),
        name: rs.getString(rs.getColumnIndex('name')),
        targetIds: PersonalDao.parseStringArray(rs.getString(rs.getColumnIndex('target_ids'))),
        updatedAt: rs.getLong(rs.getColumnIndex('updated_at')),
        createdAt: rs.getLong(rs.getColumnIndex('created_at')),
        deviceId: rs.getString(rs.getColumnIndex('device_id')),
        deleted: false,
      })
    }
    rs.close()
    return list
  }

  /** 解析存成 JSON 文本的字符串数组（ArkTS 不允许直接 as string[]） */
  static parseStringArray(text: string): string[] {    if (text.length === 0 || text === '[]') {
      return []
    }
    const parsed: Object | null = JSON.parse(text) as Object | null
    if (!Array.isArray(parsed)) {
      return []
    }
    const out: string[] = []
    for (const item of parsed as Object[]) {
      out.push(String(item))
    }
    return out
  }

  /** 把毫秒时间戳格式化成「刚刚 / N 分钟前 / N 小时前 / M月D日」 */
  static formatTime(ms: number): string {
    const diff: number = new Date().getTime() - ms
    if (diff < 60000) {
      return '刚刚'
    }
    if (diff < 3600000) {
      return `${Math.floor(diff / 60000)} 分钟前`
    }
    if (diff < 86400000) {
      return `${Math.floor(diff / 3600000)} 小时前`
    }
    const d: Date = new Date(ms)
    return `${d.getMonth() + 1} 月 ${d.getDate()} 日`
  }
}
