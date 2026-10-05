/**
 * 接口契约。
 *
 * 端侧与云侧共用；改这里必须同时通知两端（见 docs/开发规范.md §5）。
 * 本文件为纯类型，会被 tools/gen 生成为端侧 .ets。
 */

import type {
  City,
  CollectTargetType,
  Era,
  HeritageType,
  Level,
  Section,
  SyncState,
} from './constants'
import type {
  Citation,
  ConflictRecord,
  Favorite,
  GraphEdge,
  GraphNode,
  GraphRelation,
  HeritageItem,
  Note,
  SyncableRecord,
  Tag,
  Theme,
} from './models'

// ---------------------------------------------------------------------------
// 通用
// ---------------------------------------------------------------------------

/** 错误响应 */
export interface ApiError {
  readonly code: string
  readonly message: string
}

/** 统一响应包装 */
export interface ApiResult<T> {
  readonly ok: boolean
  readonly data?: T
  readonly error?: ApiError
}

/** 分页请求 */
export interface PageQuery {
  readonly page?: number
  readonly pageSize?: number
}

// ---------------------------------------------------------------------------
// 档案条目
// ---------------------------------------------------------------------------

/** 列表项（列表页不返回五层长文） */
export interface HeritageSummary {
  readonly id: string
  readonly name: string
  readonly city: City
  readonly era: Era
  readonly types: readonly HeritageType[]
  readonly level?: Level
  readonly summary: string
  /** 主图相对路径 */
  readonly cover?: string
}

export interface ItemListQuery extends PageQuery {
  readonly city?: City
  readonly era?: Era
  readonly type?: HeritageType
  /** 关键词（服务端用 BM25 做一次预筛） */
  readonly q?: string
}

export interface ItemListResponse {
  readonly total: number
  readonly page: number
  readonly pageSize: number
  readonly items: readonly HeritageSummary[]
}

export type ItemDetailResponse = HeritageItem

/** 关联推荐 */
export interface RelatedResponse {
  readonly itemId: string
  readonly related: readonly {
    readonly id: string
    readonly name: string
    readonly score: number
    /** 可解释的推荐理由，如「同属唐三彩」 */
    readonly reason: string
  }[]
}

// ---------------------------------------------------------------------------
// 检索
// ---------------------------------------------------------------------------

export interface SearchFilters {
  readonly cities?: readonly City[]
  readonly eras?: readonly Era[]
  readonly types?: readonly HeritageType[]
}

export interface SearchRequest {
  readonly query: string
  readonly filters?: SearchFilters
  /** 返回条数，默认 10 */
  readonly topK?: number
}

/** 检索命中来源 */
export type SearchChannel = 'keyword' | 'vector' | 'both'

export interface SearchHit {
  readonly itemId: string
  readonly name: string
  readonly section: Section
  /** 高亮片段 */
  readonly snippet: string
  readonly score: number
  readonly channel: SearchChannel
  /** 语义命中时给出的可解释理由 */
  readonly reason?: string
}

export interface SearchResponse {
  readonly hits: readonly SearchHit[]
  readonly tookMs: number
  /** 是否触发了降级（true 表示语义通道不可用，仅关键词） */
  readonly degraded: boolean
  /** 实际参与检索的通道 */
  readonly channels: readonly SearchChannel[]
}

// ---------------------------------------------------------------------------
// 问答（WebSocket）
// ---------------------------------------------------------------------------

export interface QaAsk {
  readonly type: 'ask'
  readonly sessionId: string
  readonly query: string
}

export interface QaAck {
  readonly type: 'ack'
  readonly sessionId: string
}

/** 流式增量 */
export interface QaDelta {
  readonly type: 'delta'
  readonly text: string
}

/** 结束帧 */
export interface QaDone {
  readonly type: 'done'
  readonly answer: string
  readonly citations: readonly Citation[]
  readonly graphPaths: readonly GraphPath[]
  /** 是否降级为抽取式回答 */
  readonly degraded: boolean
}

export interface QaError {
  readonly type: 'error'
  readonly code: string
  readonly message: string
}

export type QaClientMessage = QaAsk
export type QaServerMessage = QaAck | QaDelta | QaDone | QaError

/** 图谱路径（问答证据） */
export interface GraphPath {
  readonly from: string
  readonly fromName: string
  readonly rel: GraphRelation
  readonly to: string
  readonly toName: string
}

// ---------------------------------------------------------------------------
// 图谱
// ---------------------------------------------------------------------------

export interface SubgraphQuery {
  readonly nodeId?: string
  /** 展开层数，默认 1，上限 2 */
  readonly depth?: number
  readonly nodeTypes?: readonly string[]
}

export interface SubgraphResponse {
  readonly nodes: readonly GraphNode[]
  readonly edges: readonly GraphEdge[]
}

export interface GraphSearchResponse {
  readonly nodes: readonly GraphNode[]
}

export interface GraphPathQuery {
  readonly from: string
  readonly to: string
}

export interface GraphPathResponse {
  readonly paths: readonly GraphPath[][]
}

/** 社区（自动发现的文化主题） */
export interface Community {
  readonly id: string
  readonly name: string
  readonly nodeIds: readonly string[]
  /** 社区规模，用于可视化 */
  readonly size: number
}

export interface CommunitiesResponse {
  readonly communities: readonly Community[]
}

/** 由用户收藏生成个人主题子图 */
export interface ThemeBuildRequest {
  readonly name: string
  readonly targetIds: readonly string[]
}

export interface ThemeBuildResponse {
  readonly theme: Theme
  readonly nodes: readonly GraphNode[]
  readonly edges: readonly GraphEdge[]
  /** 算法推荐的拓展条目 */
  readonly suggestions: readonly string[]
}

// ---------------------------------------------------------------------------
// 同步（WebSocket）
// ---------------------------------------------------------------------------

/** 单表变更集 */
export interface ChangeSet {
  readonly table: 'favorites' | 'notes' | 'tags' | 'themes'
  readonly records: readonly SyncableRecord[]
}

export interface SyncPush {
  readonly type: 'push'
  readonly deviceId: string
  readonly changes: readonly ChangeSet[]
}

export interface SyncPull {
  readonly type: 'pull'
  readonly deviceId: string
  /** 上次同步游标（毫秒时间戳） */
  readonly since: number
}

export interface SyncProgress {
  readonly type: 'progress'
  readonly done: number
  readonly total: number
  readonly direction: string
}

export interface SyncApplied {
  readonly type: 'applied'
  readonly applied: number
  readonly conflicts: readonly ConflictRecord[]
}

export interface SyncPulled {
  readonly type: 'pulled'
  readonly changes: readonly ChangeSet[]
  readonly conflicts: readonly ConflictRecord[]
  readonly serverTime: number
}

export interface SyncStateMessage {
  readonly type: 'state'
  readonly state: SyncState
}

export type SyncClientMessage = SyncPush | SyncPull
export type SyncServerMessage =
  | SyncProgress
  | SyncApplied
  | SyncPulled
  | SyncStateMessage
  | QaError

// ---------------------------------------------------------------------------
// 备份与恢复
// ---------------------------------------------------------------------------

/** 备份载荷（本地导出与云端快照共用） */
export interface BackupPayload {
  readonly version: string
  readonly exportedAt: number
  readonly deviceId: string
  readonly favorites: readonly Favorite[]
  readonly notes: readonly Note[]
  readonly tags: readonly Tag[]
  readonly themes: readonly Theme[]
}

export interface ImportResult {
  readonly imported: number
  readonly merged: number
  readonly conflicts: readonly ConflictRecord[]
}

/** 云端快照列表项 */
export interface BackupSnapshot {
  readonly id: string
  readonly createdAt: number
  readonly sizeBytes: number
  readonly itemCount: number
}

// ---------------------------------------------------------------------------
// 统计
// ---------------------------------------------------------------------------

export interface UsageEntry {
  readonly callCount: number
  readonly tokens: number
  readonly totalMs: number
  readonly errorCount: number
}

export interface UsageStats {
  /** 按 provider/operation 聚合，如 dashscope:embedding */
  readonly byOperation: Record<string, UsageEntry>
  readonly since: number
  readonly until: number
}

// ---------------------------------------------------------------------------
// 身份
// ---------------------------------------------------------------------------

export type IdentityType = 'openid' | 'paired'

export interface IdentityInfo {
  readonly userId: string
  readonly type: IdentityType
  readonly displayName?: string
}

/** 配对码绑定 */
export interface PairingRequest {
  readonly code: string
  readonly deviceId: string
}

export interface PairingResponse {
  readonly code: string
  /** 配对码有效期（秒） */
  readonly expiresIn: number
}

// ---------------------------------------------------------------------------
// 收藏 / 笔记（REST 备选通道，主通道为同步）
// ---------------------------------------------------------------------------

export interface CollectRequest {
  readonly targetType: CollectTargetType
  readonly targetId: string
  readonly tagIds?: readonly string[]
}
