/**
 * 同步编排：通道选择、一轮同步、身份绑定。
 *
 * **主次纪律**（设计文档 §8.1）：通道 A（鸿蒙分布式数据服务）是主路径 ——
 * 赛题把「基于鸿蒙分布式数据服务」写在主要功能里。通道 B（云端）只在
 * A 不可用或信任环内没有对端时才启用，服务于跨网络与设备不足的场景。
 *
 * 这个选择顺序是有意的：若两个通道总是并跑，答辩时无法说明主次，
 * 而且会把「云端」变成事实上的主要方案，正是赛题要求避免的误读。
 */

import { common } from '@kit.AbilityKit'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { http } from '@kit.NetworkKit'

import type { BackupSnapshot, ChangeSet, ConflictRecord, SyncableRecord } from '../../shared'
import { SyncKeys } from '../../model/Schema'
import { DataImportService } from '../DataImportService'
import { PersonalDao } from '../PersonalDao'
import { CloudSync } from './CloudSync'
import { DistributedSync } from './DistributedSync'
import type { ChannelStatus, ChangeListener, SyncOutcome } from './Types'
import { SyncPhase } from './Types'

/**
 * 默认服务端地址。
 *
 * 用域名而不是 IP：真机不在开发机的局域网里，只能用公网地址。
 * 运行时可在「我的 → 跨设备同步 → 云端」覆盖，改完即生效。
 *
 * 注意：走 https 是因为鸿蒙默认拦明文流量。若服务端暂时只有 http，
 * 需要在 module.json5 里放行 cleartext，否则请求会被系统直接断掉。
 */
export const DEFAULT_BASE_URL: string = 'https://yra.young143.top'

/**
 * 具名接口 —— ArkTS 不允许用内联对象字面量做类型声明
 * （arkts-no-obj-literals-as-types），因此每个返回形状都要有名字。
 */
export interface PairingCreatedView {
  readonly code: string
  readonly userId: string
  readonly message: string
}

/** 服务端备份接口的响应体 */
export interface SnapshotResultView {
  readonly ok: boolean
  readonly message: string
}

export interface SnapshotListView {
  readonly snapshots: BackupSnapshot[]
}

export interface SnapshotRestoreView {
  readonly ok: boolean
  readonly message: string
  readonly changes: ChangeSet[]
}

/** 服务端 /api/sync/pair/join 的响应体 */
export interface JoinApiResponse {
  readonly ok: boolean
  readonly userId: string
  readonly message: string
}

/** 对 UI 暴露的配对结果 */
export interface JoinResultView {
  readonly ok: boolean
  readonly message: string
}

/**
 * 同步进度（对应赛题原文「清晰展示'手机→平板'的同步进度」）。
 * done 为已完成条数，total 为总条数，direction 为方向标识。
 */
export interface SyncProgressView {
  readonly done: number
  readonly total: number
  readonly direction: string
}

/** 一次同步的汇总，供 UI 展示 */
export interface SyncSummary {
  readonly outcome: SyncOutcome
  /** 实际使用的通道名（主路径优先） */
  readonly channel: string
  readonly conflicts: ConflictRecord[]
}

function now(): number {
  return new Date().getTime()
}

export class SyncService {
  private static distributed: DistributedSync | undefined = undefined
  private static cloud: CloudSync | undefined = undefined
  private static listener: ChangeListener | undefined = undefined

  /** 初始化两个通道（幂等）。任一失败都不抛异常 —— 另一个仍可用 */
  static async init(context: common.Context): Promise<void> {
    if (SyncService.distributed === undefined) {
      SyncService.distributed = new DistributedSync()
    }
    if (SyncService.cloud === undefined) {
      SyncService.cloud = new CloudSync()
      const stored: string = await PersonalDao.getSyncMeta(context, 'syncBaseUrl')
      SyncService.cloud.setBaseUrl(stored.length > 0 ? stored : DEFAULT_BASE_URL)
      if (SyncService.listener !== undefined) {
        SyncService.cloud.subscribe(SyncService.listener)
      }
    }
    try {
      await SyncService.distributed.init(context)
    } catch (err) {
      // 通道 A 不可用属于常见情况（无信任环），不视为错误
    }
    await SyncService.ensureCloud(context)
  }

  /** 确保云通道已连接（未绑定身份时跳过） */
  private static async ensureCloud(context: common.Context): Promise<boolean> {
    const cloud: CloudSync | undefined = SyncService.cloud
    if (cloud === undefined) {
      return false
    }
    const userId: string = await PersonalDao.getSyncMeta(context, SyncKeys.USER_ID)
    if (userId.length === 0) {
      return false
    }
    const deviceId: string = await PersonalDao.getDeviceId(context)
    const deviceName: string = await PersonalDao.getSyncMeta(context, SyncKeys.DEVICE_NAME)
    return cloud.init(context, userId, deviceId, deviceName)
  }

  /** 当前绑定的身份（空串表示未绑定） */
  static async currentUserId(context: common.Context): Promise<string> {
    return PersonalDao.getSyncMeta(context, SyncKeys.USER_ID)
  }

  /**
   * 设备 A：生成配对码（绑定新身份或复用现有身份）。
   * 返回 6 位码与身份标识。
   */
  static async createPairing(
    context: common.Context,
    deviceName: string
  ): Promise<PairingCreatedView> {
    const baseUrl: string = await SyncService.resolveBaseUrl(context)
    const existing: string = await PersonalDao.getSyncMeta(context, SyncKeys.USER_ID)
    try {
      const text: string = await SyncService.postJson(
        `${baseUrl}/api/sync/pair`,
        JSON.stringify({ userId: existing })
      )
      const body = JSON.parse(text) as PairingCreatedView
      if (body.code === undefined || body.userId === undefined) {
        return { code: '', userId: '', message: '服务端未返回配对码' }
      }
      await PersonalDao.setSyncMeta(context, SyncKeys.USER_ID, body.userId)
      await PersonalDao.setSyncMeta(context, SyncKeys.DEVICE_NAME, deviceName)
      return { code: body.code, userId: body.userId, message: '配对码已生成，请在另一台设备上输入' }
    } catch (err) {
      return { code: '', userId: '', message: `无法连接服务端（${SyncService.describeError(err)})` }
    }
  }

  /** 设备 B：输入配对码加入 */
  static async joinPairing(
    context: common.Context,
    code: string,
    deviceName: string
  ): Promise<JoinResultView> {
    const baseUrl: string = await SyncService.resolveBaseUrl(context)
    const deviceId: string = await PersonalDao.getDeviceId(context)
    try {
      const text: string = await SyncService.postJson(
        `${baseUrl}/api/sync/pair/join`,
        JSON.stringify({ code: code, deviceId: deviceId, deviceName: deviceName })
      )
      const body = JSON.parse(text) as JoinApiResponse
      if (body.ok !== true) {
        return { ok: false, message: body.message !== undefined ? body.message : '配对失败' }
      }
      await PersonalDao.setSyncMeta(context, SyncKeys.USER_ID, body.userId)
      await PersonalDao.setSyncMeta(context, SyncKeys.DEVICE_NAME, deviceName)
      return { ok: true, message: '配对成功' }
    } catch (err) {
      return { ok: false, message: `无法连接服务端（${SyncService.describeError(err)})` }
    }
  }

  /** 注册同步进度回调（同步中心页画进度条用） */
  static onProgress(handler: (progress: SyncProgressView) => void): void {
    const cloud: CloudSync | undefined = SyncService.cloud
    if (cloud !== undefined) {
      cloud.onProgress((done: number, total: number, direction: string) => {
        handler({ done, total, direction })
      })
    }
  }

  /** 最近的冲突记录（同步中心展示「双方版本、时间戳、最终采用哪一方」） */
  static async recentConflicts(context: common.Context, limit: number): Promise<ConflictRecord[]> {
    return PersonalDao.listConflicts(context, limit)
  }

  /** 订阅对端变更（云通道的实时广播） */
  static subscribe(context: common.Context, listener: ChangeListener): void {
    SyncService.listener = listener
    const cloud: CloudSync | undefined = SyncService.cloud
    if (cloud !== undefined) {
      cloud.subscribe(listener)
    }
    void context
  }

  /** 设置服务端地址并持久化 */
  static async setBaseUrl(context: common.Context, url: string): Promise<void> {
    await PersonalDao.setSyncMeta(context, 'syncBaseUrl', url)
    const cloud: CloudSync | undefined = SyncService.cloud
    if (cloud !== undefined) {
      cloud.setBaseUrl(url)
    }
  }

  private static async resolveBaseUrl(context: common.Context): Promise<string> {
    const stored: string = await PersonalDao.getSyncMeta(context, 'syncBaseUrl')
    return stored.length > 0 ? stored : DEFAULT_BASE_URL
  }

  /**
   * 跑一轮同步。
   *
   * 顺序：先试通道 A（有对端就用它），否则退到通道 B。
   * 两端都做「先推后拉」—— 先推能让本机改动尽快到达服务端，
   * 再拉则拿到包括本机刚才推上去的在内的完整状态，避免来回两轮。
   */
  static async sync(context: common.Context): Promise<SyncSummary> {
    const started: number = now()
    const deviceId: string = await PersonalDao.getDeviceId(context)
    // 两个游标语义完全不同，必须分开存：
    //   lastPushedAt —— 本机记录时间戳，用于「哪些本地改动还没推上去」
    //   lastPulledAt —— 服务端自增序号，用于「服务端哪些变更还没拉下来」
    // 曾把前者当后者传给服务端，量级差 12 个数量级（1.79e12 vs 1..N），
    // 结果是首次同步之后**永远拉不到任何东西**且不报错。
    const lastPushed: number = SyncService.parseInt(
      await PersonalDao.getSyncMeta(context, SyncKeys.LAST_PUSHED_AT)
    )
    const lastPulled: number = SyncService.parseInt(
      await PersonalDao.getSyncMeta(context, SyncKeys.LAST_PULLED_AT)
    )

    const localChanges: ChangeSet[] = await PersonalDao.collectChanges(context, lastPushed)
    let localCount: number = 0
    for (const set of localChanges) {
      localCount += set.records.length
    }
    hilog.info(0x0000, 'syncDiag', 'sync start: lastPushed=%{public}d localChanges=%{public}d sets=%{public}d',
      lastPushed, localCount, localChanges.length)

    // ---- 通道选择 ----
    const distributed: DistributedSync | undefined = SyncService.distributed
    let channelName: string = '未连接'
    let pushed: number = 0
    let pulled: ChangeSet[] = []
    let usedCloud: boolean = false

    const distributedStatus = distributed !== undefined ? await distributed.status() : undefined
    const distributedUsable: boolean =
      distributedStatus !== undefined && distributedStatus.available && distributed !== undefined

    if (distributedUsable && distributed !== undefined) {
      pushed = await distributed.push(localChanges, deviceId)
      pulled = await distributed.pull(lastPulled, deviceId)
      channelName = distributed.name
      // 信任环内没有对端时推送不出去，此时退到云端。
      // 判据必须是「对端数量」而不是「pull 是否非空」—— 后者会把本地残留误判成对端。
      if (!distributed.hasPeers()) {
        usedCloud = true
      }
    } else {
      usedCloud = true
    }

    if (usedCloud) {
      const cloudReady: boolean = await SyncService.ensureCloud(context)
      const cloud: CloudSync | undefined = SyncService.cloud
      if (cloudReady && cloud !== undefined) {
        const cloudPushed: number = await cloud.push(localChanges, deviceId)
        const cloudPulled: ChangeSet[] = await cloud.pull(lastPulled, deviceId)
        // 服务端游标由服务端给出（自增序号），客户端只负责存下来
        const serverCursor: number = cloud.takeCursor()
        if (serverCursor > lastPulled) {
          await PersonalDao.setSyncMeta(context, SyncKeys.LAST_PULLED_AT, `${serverCursor}`)
        }
        channelName = cloud.name
        pushed = cloudPushed
        pulled = cloudPulled
      } else if (channelName === '未连接') {
        channelName = '通道不可用'
      }
    }

    // ---- 应用远端变更 ----
    let applied: number = 0
    let conflicts: ConflictRecord[] = []
    if (pulled.length > 0) {
      const report = await PersonalDao.applyRemote(context, pulled)
      applied = report.applied
      conflicts = report.conflicts
    }

    // ---- 推进游标 ----
    hilog.info(0x0000, 'syncDiag', 'sync done: channel=%{public}s pushed=%{public}d pulledSets=%{public}d applied=%{public}d',
      channelName, pushed, pulled.length, applied)

    const finished: number = now()
    if (localChanges.length > 0 || pushed > 0) {
      await PersonalDao.setSyncMeta(context, SyncKeys.LAST_PUSHED_AT, `${finished}`)
    }
    // 注意：这里**不能**写 LAST_PULLED_AT —— 它是服务端序号，只能由服务端返回值推进。
    // 写成本机时间戳会让后续 pull 永远返回空。
    await PersonalDao.setSyncMeta(context, SyncKeys.LAST_SYNC_AT, `${finished}`)

    let pulledCount: number = 0
    for (const set of pulled) {
      pulledCount += set.records.length
    }

    const ok: boolean = channelName !== '通道不可用'
    const outcome: SyncOutcome = {
      ok,
      phase: ok ? SyncPhase.DONE : SyncPhase.FAILED,
      pushed,
      pulled: pulledCount,
      applied,
      conflicts,
      direction: channelName === '分布式软总线' ? '与其他设备' : '与云端',
      elapsedMs: finished - started,
      message: !ok
        ? '连不上，检查一下网络'
        : (pushed + applied === 0
            ? '已经是最新的，没有新内容'
            : `同步完成：本机发出 ${pushed} 条，收到 ${applied} 条`),
    }

    return { outcome, channel: channelName, conflicts }
  }

  /**
   * 重置推送游标。
   *
   * 存在的理由：游标一旦被错误地推进（历史版本曾用 `now()` 作游标，
   * 会把此前所有本地数据永久跳过），后续同步就再也看不到那些数据 ——
   * 且**没有任何报错**，表现为「明明有收藏却推送 0 条」。
   * 给用户留一个重置出口，比让数据永远同步不出去要好。
   */
  static async resetCursor(context: common.Context): Promise<void> {
    // 两个游标都要清：一个是本机时间戳、一个是服务端序号，各自的「从头开始」含义不同
    await PersonalDao.setSyncMeta(context, SyncKeys.LAST_PUSHED_AT, '0')
    await PersonalDao.setSyncMeta(context, SyncKeys.LAST_PULLED_AT, '0')
  }

  /** 保存云端快照（备份点） */
  static async saveCloudSnapshot(context: common.Context): Promise<string> {
    const baseUrl: string = await SyncService.resolveBaseUrl(context)
    const userId: string = await SyncService.currentUserId(context)
    if (userId.length === 0) {
      return '未绑定身份，无法保存云端快照'
    }
    try {
      const text: string = await SyncService.postJson(
        `${baseUrl}/api/backup/snapshot`,
        JSON.stringify({ userId: userId })
      )
      const body = JSON.parse(text) as SnapshotResultView
      return body.ok === true ? body.message : '保存失败'
    } catch (err) {
      return `无法连接服务端（${SyncService.describeError(err)})`
    }
  }

  /** 列出云端快照 */
  static async listCloudSnapshots(context: common.Context): Promise<BackupSnapshot[]> {
    const baseUrl: string = await SyncService.resolveBaseUrl(context)
    const userId: string = await SyncService.currentUserId(context)
    if (userId.length === 0) {
      return []
    }
    try {
      const request = http.createHttp()
      try {
        const response: http.HttpResponse = await request.request(
          `${baseUrl}/api/backup/snapshots?userId=${encodeURIComponent(userId)}&limit=10`,
          { method: http.RequestMethod.GET, connectTimeout: 6000, readTimeout: 8000 }
        )
        const body = JSON.parse(String(response.result)) as SnapshotListView
        return body.snapshots !== undefined ? body.snapshots : []
      } finally {
        request.destroy()
      }
    } catch (err) {
      return []
    }
  }

  /**
   * 从云端快照恢复。
   *
   * 走的是与同步相同的 LWW 合并路径 —— 快照被当作一批「远端变更」应用，
   * **不直接覆盖本地**。否则「恢复到旧快照」会悄悄回退掉快照之后的所有改动，
   * 而用户点「恢复」时通常并不期望这个语义。
   */
  static async restoreSnapshot(context: common.Context, snapshotId: string): Promise<string> {
    const baseUrl: string = await SyncService.resolveBaseUrl(context)
    const userId: string = await SyncService.currentUserId(context)
    if (userId.length === 0) {
      return '未绑定身份'
    }
    try {
      const text: string = await SyncService.postJson(
        `${baseUrl}/api/backup/snapshots/${encodeURIComponent(snapshotId)}/restore`,
        JSON.stringify({ userId: userId })
      )
      const body = JSON.parse(text) as SnapshotRestoreView
      if (body.changes === undefined) {
        return body.message !== undefined ? body.message : '快照读取失败'
      }
      const report = await PersonalDao.applyRemote(context, body.changes)
      return `已按最新时间戳合并：应用 ${report.applied} 条、保留本地 ${report.skipped} 条、冲突 ${report.conflicts.length} 条`
    } catch (err) {
      return `恢复失败（${SyncService.describeError(err)})`
    }
  }

  /** 各通道的可读状态（同步中心页展示） */
  /**
   * 一句话同步状态。
   *
   * 界面上只留这一句人话。原先展示的是三条技术行话
   * （「分布式软总线（主路径）：本机可用，信任环内未发现其他设备」、
   *  「云端存储（兜底）：已连接 …」、「身份：u_xxx｜本机：xxx」），
   * 用户看不出这些是什么意思，答辩时也不需要把它们摆在首页。
   */
  static async statusLine(context: common.Context): Promise<string> {
    const cloud: CloudSync | undefined = SyncService.cloud
    let link: string = '云端未连接'
    if (cloud !== undefined) {
      const status: ChannelStatus = await cloud.status()
      link = status.available ? '云端已连接' : '云端未连接'
    }
    return `${link} · ${await SyncService.lastSyncWords(context)}`
  }

  /** 上次同步的相对时间。没同步过就说「还没同步过」，不要摆 1970 年 */
  static async lastSyncWords(context: common.Context): Promise<string> {
    const raw: string = await PersonalDao.getSyncMeta(context, SyncKeys.LAST_SYNC_AT)
    const at: number = Number.parseInt(raw.length > 0 ? raw : '0', 10)
    if (Number.isNaN(at) || at <= 0) {
      return '还没同步过'
    }
    const minutes: number = Math.floor((new Date().getTime() - at) / 60000)
    if (minutes < 1) {
      return '刚刚同步过'
    }
    if (minutes < 60) {
      return `${minutes} 分钟前同步过`
    }
    const hours: number = Math.floor(minutes / 60)
    if (hours < 24) {
      return `${hours} 小时前同步过`
    }
    return `${Math.floor(hours / 24)} 天前同步过`
  }

  /** 仅自检脚本使用：把两条通道的原始状态打出来 */
  static async channelReport(context: common.Context): Promise<string[]> {
    const lines: string[] = []
    const distributed: DistributedSync | undefined = SyncService.distributed
    if (distributed !== undefined) {
      const status = await distributed.status()
      lines.push(`${status.name}（主路径）：${status.detail}`)
    } else {
      lines.push('分布式软总线（主路径）：未初始化')
    }

    const cloud: CloudSync | undefined = SyncService.cloud
    if (cloud !== undefined) {
      const status = await cloud.status()
      const baseUrl: string = await SyncService.resolveBaseUrl(context)
      lines.push(`${status.name}（兜底）：${status.detail}｜${baseUrl}`)
    } else {
      lines.push('云端存储（兜底）：未初始化')
    }

    const userId: string = await SyncService.currentUserId(context)
    const deviceId: string = await PersonalDao.getDeviceId(context)
    lines.push(
      `身份：${userId.length > 0 ? `${userId.slice(0, 14)}…` : '未绑定'}｜本机：${deviceId.slice(0, 8)}…`
    )
    return lines
  }

  /** POST JSON 并返回响应文本（ArkTS 没有全局 fetch，用 @ohos.net.http） */
  private static async postJson(url: string, body: string): Promise<string> {
    const request = http.createHttp()
    try {
      const response: http.HttpResponse = await request.request(url, {
        method: http.RequestMethod.POST,
        header: { 'Content-Type': 'application/json' },
        extraData: body,
        connectTimeout: 6000,
        readTimeout: 8000,
      })
      return String(response.result)
    } finally {
      request.destroy()
    }
  }

  private static parseInt(text: string): number {
    if (text.length === 0) {
      return 0
    }
    const value: number = Number.parseInt(text, 10)
    return Number.isFinite(value) ? value : 0
  }

  private static describeError(err: Object): string {
    return err instanceof Error ? err.message.slice(0, 80) : '网络错误'
  }
}

/** 供 UI 直接引用的记录类型转出（避免页面里到处 import shared） */
export type { ChangeSet, SyncableRecord }
