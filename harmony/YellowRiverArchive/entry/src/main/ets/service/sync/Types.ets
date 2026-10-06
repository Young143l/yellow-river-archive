/**
 * 同步通道的公共契约。
 *
 * ArkTS 约束（ADR-019）：不用 as const、typeof 类型查询、内联对象类型、
 * 未标注的对象字面量、数组展开。回调也不用函数类型，改用单方法接口 ——
 * 函数类型在 ArkTS 里能写但传递时限制多，接口形式更稳。
 */

import type { ChangeSet, ConflictRecord, SyncableRecord } from '../../shared'

/** 同步阶段（同步中心页据此显示文案与进度） */
export enum SyncPhase {
  IDLE = 'idle',
  PREPARING = 'preparing',
  PUSHING = 'pushing',
  PULLING = 'pulling',
  APPLYING = 'applying',
  DONE = 'done',
  FAILED = 'failed',
}

/** 同步结果 */
export interface SyncOutcome {
  readonly ok: boolean
  readonly phase: SyncPhase
  readonly pushed: number
  readonly pulled: number
  readonly applied: number
  readonly conflicts: ConflictRecord[]
  readonly direction: string
  readonly elapsedMs: number
  readonly message: string
}

/** 通道状态 */
export interface ChannelStatus {
  readonly name: string
  readonly available: boolean
  readonly detail: string
}

/** 变更监听者 */
export interface ChangeListener {
  onChanges(changes: ChangeSet[]): void
}

/**
 * 同步适配器。
 *
 * 刻意保持极小：四种能力（推、拉、订阅、查状态）。
 * 具体通道（分布式 KV / 云端）各自实现，上层不关心差异。
 */
export interface SyncAdapter {
  /** 通道标识，展示用 */
  readonly name: string

  /** 通道当前是否可用（分布式软总线可能没连上，云可能没网） */
  available(): Promise<boolean>

  /** 推送变更，返回实际送达的条数 */
  push(changes: ChangeSet[], deviceId: string): Promise<number>

  /** 拉取游标之后的变更 */
  pull(since: number, deviceId: string): Promise<ChangeSet[]>

  /** 订阅对端变更（仅通道 A 支持；通道 B 走轮询） */
  subscribe(listener: ChangeListener): void

  unsubscribe(): void

  status(): Promise<ChannelStatus>
}

/** 所有可同步记录的最小形状，用于统一的 LWW 比较 */
export interface SyncEnvelope {
  readonly id: string
  readonly updatedAt: number
  readonly createdAt: number
  readonly deviceId: string
  readonly deleted: boolean
}

/**
 * 把任意可同步记录收敛成 SyncEnvelope。
 * ChangeSet.records 的类型是 SyncableRecord，各业务表在前面加上自己的字段。
 */
export function toEnvelope(record: SyncableRecord): SyncEnvelope {
  return {
    id: record.id,
    updatedAt: record.updatedAt,
    createdAt: record.createdAt,
    deviceId: record.deviceId,
    deleted: record.deleted,
  }
}

/**
 * LWW 胜负判定。
 *
 * 时间戳相同（两端在同一毫秒各自修改）时用 deviceId 字典序兜底。
 * **必须是确定性且两端一致的规则** —— 若一端判「本地赢」另一端判「远端赢」，
 * 两台设备会永久分叉，而且每次同步都各自"修改"一遍，永远收敛不了。
 */
export function remoteWins(local: SyncEnvelope, remote: SyncEnvelope): boolean {
  if (remote.updatedAt !== local.updatedAt) {
    return remote.updatedAt > local.updatedAt
  }
  return remote.deviceId > local.deviceId
}

/** 判断两个信封是否完全一致（一致就不必写库，省掉一次无谓更新） */
export function isSameVersion(local: SyncEnvelope, remote: SyncEnvelope): boolean {
  return (
    local.updatedAt === remote.updatedAt &&
    local.deviceId === remote.deviceId &&
    local.deleted === remote.deleted
  )
}
