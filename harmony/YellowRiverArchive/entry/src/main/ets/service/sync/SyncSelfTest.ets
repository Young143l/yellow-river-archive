/**
 * 同步链路自检。
 *
 * 用途有两个：
 *   1. 开发期验证 —— 本机就能跑通「写入 → 读回 → LWW 合并 → 分布式 KV 存取」
 *      这条完整链路，不需要第二台设备
 *   2. 路演兜底 —— 现场若对端设备出问题，可在同步中心点「自检」证明链路本身是好的
 *
 * 所有测试数据跑完即清理，可重复运行。
 */

import { common } from '@kit.AbilityKit'
import { relationalStore } from '@kit.ArkData'

import type { ChangeSet, ConflictRecord, Favorite, SyncableRecord } from '../../shared'
import { Tables } from '../../model/Schema'
import { DataImportService } from '../DataImportService'
import { favoriteId, PersonalDao } from '../PersonalDao'
import { DistributedSync } from './DistributedSync'
import { remoteWins, type SyncEnvelope } from './Types'

/** 自检使用的前缀，便于识别与清理 */
const TEST_PREFIX: string = 'selftest'

export interface SelfTestLine {
  readonly name: string
  readonly ok: boolean
  readonly detail: string
}

export interface SelfTestReport {
  readonly passed: number
  readonly failed: number
  readonly lines: SelfTestLine[]
  readonly elapsedMs: number
}

export class SyncSelfTest {
  /** 跑一遍自检，返回逐项结果 */
  static async run(context: common.Context): Promise<SelfTestReport> {
    const started: number = new Date().getTime()
    const lines: SelfTestLine[] = []

    const add = (name: string, ok: boolean, detail: string): void => {
      lines.push({ name, ok, detail })
    }

    const targetId: string = `${TEST_PREFIX}-item`

    try {
      // ---- 1. 收藏写入与读回（含确定性 id） ----
      const before: boolean = await PersonalDao.isFavorite(context, 'site', targetId)
      const toggled: boolean = await PersonalDao.toggleFavorite(context, 'site', targetId)
      const after: boolean = await PersonalDao.isFavorite(context, 'site', targetId)
      add(
        '收藏写入与读回',
        !before && toggled && after,
        `id=${favoriteId('site', targetId)} 切换前=${before} 切换后=${after}`
      )

      // ---- 2. 已读记录 ----
      await PersonalDao.recordVisit(context, targetId)
      const visited: Set<string> = await PersonalDao.visitedIds(context)
      add('已读记录', visited.has(targetId), `已读条目数=${visited.size}`)

      // ---- 3. 笔记增改删 ----
      const noteId: string = await PersonalDao.addNote(context, 'site', targetId, '自检笔记-初稿')
      await PersonalDao.updateNote(context, noteId, '自检笔记-修改后')
      const notes = await PersonalDao.listNotes(context, targetId)
      const editedOk: boolean = notes.length > 0 && notes[0].content === '自检笔记-修改后'
      await PersonalDao.deleteNote(context, noteId)
      const afterDelete = await PersonalDao.listNotes(context, targetId)
      add(
        '笔记增改删',
        editedOk && afterDelete.length === 0,
        `修改后内容正确=${editedOk} 软删后剩余=${afterDelete.length}（应为 0，说明软删对查询生效）`
      )

      // ---- 4. 变更收集（待推送集） ----
      const changes: ChangeSet[] = await PersonalDao.collectChanges(context, 0)
      let recordCount: number = 0
      for (const set of changes) {
        recordCount += set.records.length
      }
      add('变更收集', recordCount > 0, `收集到 ${recordCount} 条变更，涉及 ${changes.length} 张表`)

      // ---- 5. LWW 收敛规则 ----
      const older: SyncEnvelope = { id: 'x', updatedAt: 1000, createdAt: 1000, deviceId: 'device-a', deleted: false }
      const newer: SyncEnvelope = { id: 'x', updatedAt: 2000, createdAt: 1000, deviceId: 'device-b', deleted: false }
      const sameTimeLargerDevice: SyncEnvelope = { id: 'x', updatedAt: 1000, createdAt: 1000, deviceId: 'device-z', deleted: false }
      const sameTimeSmallerDevice: SyncEnvelope = { id: 'x', updatedAt: 1000, createdAt: 1000, deviceId: 'device-a', deleted: false }

      const tsWins: boolean = remoteWins(older, newer) && !remoteWins(newer, older)
      // 时间戳相同时靠 deviceId 兜底。关键是**两个方向判定相反** ——
      // 若都判本地赢，两台设备会永久分叉
      const tieBreak: boolean =
        remoteWins(older, sameTimeLargerDevice) && !remoteWins(older, sameTimeSmallerDevice)
      add(
        'LWW 收敛规则',
        tsWins && tieBreak,
        `时间戳新者胜=${tsWins} 同时刻按 deviceId 判定且方向相反=${tieBreak}`
      )

      // ---- 6. 远端合并（模拟对端推来一条更新的记录） ----
      const remoteFavorite: Favorite = {
        id: favoriteId('site', targetId),
        targetType: 'site',
        targetId,
        tagIds: [],
        updatedAt: new Date().getTime() + 60000,
        createdAt: new Date().getTime(),
        deviceId: 'remote-device',
        deleted: false,
      }
      const applyResult = await PersonalDao.applyRemote(context, [
        { table: Tables.FAVORITES, records: [remoteFavorite as SyncableRecord] },
      ])
      add(
        '远端合并与同版本幂等',
        applyResult.applied === 1,
        `应用 ${applyResult.applied} 条，跳过 ${applyResult.skipped} 条，冲突 ${applyResult.conflicts.length} 条`
      )

      // 同一批再应用一次，应该全部跳过（幂等）
      const again = await PersonalDao.applyRemote(context, [
        { table: Tables.FAVORITES, records: [remoteFavorite as SyncableRecord] },
      ])
      add('重复应用幂等', again.applied === 0 && again.skipped === 1, `第二次应用 ${again.applied} 条、跳过 ${again.skipped} 条`)

      // ---- 7. 冲突日志 ----
      const conflicts: ConflictRecord[] = await PersonalDao.listConflicts(context)
      add('冲突日志写入', conflicts.length > 0, `冲突记录 ${conflicts.length} 条`)

      // ---- 8. 分布式 KV（通道 A） ----
      const distributed = new DistributedSync()
      // 注意顺序：必须先 init 再清场 —— 未 init 时 store 还是空的，清场会静默无效
      const opened: boolean = await distributed.init(context)
      if (opened) {
        // 上次自检留在分布式 KV 里的探针会被 pull 当成「对端推来的数据」，
        // 污染后续同步结果（实测就踩到了：一次真实同步里拉回了这个残留）
        await distributed.debugClearPrefix(Tables.FAVORITES)
      }
      if (!opened) {
        add('分布式 KV 打开', false, '通道 A 不可用（权限或系统服务问题）')
      } else {
        const store: relationalStore.RdbStore = await DataImportService.open(context)
        void store
        const probe: Favorite = {
          id: `${TEST_PREFIX}-kv`,
          targetType: 'site',
          targetId: `${TEST_PREFIX}-kv`,
          tagIds: [],
          updatedAt: new Date().getTime(),
          createdAt: new Date().getTime(),
          deviceId: await PersonalDao.getDeviceId(context),
          deleted: false,
        }
        const written: number = await distributed.push(
          [{ table: Tables.FAVORITES, records: [probe as SyncableRecord] }],
          probe.deviceId
        )

        // 分开验证「单键读回」与「前缀扫描」—— 两者失败原因不同：
        // 前者说明写没落盘，后者说明前缀匹配语义与预期不符
        const directRead: string = await distributed.debugGet(
          Tables.FAVORITES,
          probe.id
        )
        const prefixCount: number = await distributed.debugCountPrefix(Tables.FAVORITES)

        const pulled: ChangeSet[] = await distributed.pull(0, probe.deviceId)
        let pulledCount: number = 0
        for (const set of pulled) {
          pulledCount += set.records.length
        }
        const status: string = (await distributed.status()).detail
        add(
          '分布式 KV 写入',
          written === 1 && directRead.length > 0,
          `写入 ${written} 条，单键直读${directRead.length > 0 ? '成功' : '失败'}（${directRead.length} 字节）`
        )
        add(
          '分布式 KV 前缀扫描',
          prefixCount > 0,
          `前缀匹配 ${prefixCount} 条，pull 读回 ${pulledCount} 条｜${status}`
        )
      }

      // ---- 9. 进度统计 ----
      const progress = await PersonalDao.overallProgress(context)
      const deviceId: string = await PersonalDao.getDeviceId(context)
      add(
        '进度统计与设备标识',
        deviceId.length > 0,
        `已读 ${progress.done}/${progress.total}，本机 deviceId=${deviceId.slice(0, 8)}…`
      )
    } catch (err) {
      const message: string = err instanceof Error ? err.message : String(err)
      add('自检过程', false, `异常：${message}`)
    } finally {
      await SyncSelfTest.cleanup(context, targetId)
    }

    let passed: number = 0
    let failed: number = 0
    for (const line of lines) {
      if (line.ok) {
        passed += 1
      } else {
        failed += 1
      }
    }

    return {
      passed,
      failed,
      lines,
      elapsedMs: new Date().getTime() - started,
    }
  }

  /** 清理自检数据（物理删除，不留软删墓碑污染同步） */
  private static async cleanup(context: common.Context, targetId: string): Promise<void> {
    try {
      const store: relationalStore.RdbStore = await DataImportService.open(context)
      await store.executeSql(`DELETE FROM ${Tables.FAVORITES} WHERE target_id LIKE ?`, [`${TEST_PREFIX}%`])
      await store.executeSql(`DELETE FROM ${Tables.NOTES} WHERE target_id LIKE ?`, [`${TEST_PREFIX}%`])
      await store.executeSql(`DELETE FROM ${Tables.VISITS} WHERE item_id LIKE ?`, [`${TEST_PREFIX}%`])
      await store.executeSql(`DELETE FROM ${Tables.CONFLICTS} WHERE record_id LIKE ?`, [`${TEST_PREFIX}%`])
      void targetId
    } catch (err) {
      // 清理失败不该让自检结果失真
    }
  }

  /** 把结果格式化成可打印的多行文本 */
  static format(report: SelfTestReport): string {
    const parts: string[] = []
    parts.push(`[SyncSelfTest] ${report.passed} 通过 / ${report.failed} 失败，耗时 ${report.elapsedMs}ms`)
    for (const line of report.lines) {
      parts.push(`  ${line.ok ? 'PASS' : 'FAIL'}  ${line.name} —— ${line.detail}`)
    }
    return parts.join('\n')
  }
}
