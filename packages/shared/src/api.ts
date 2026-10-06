/**
 * 接口契约。
 *
 * 端侧与云侧共用；改这里必须同时通知两端（见 docs/开发规范.md §5）。
 * 约束：会生成为端侧 .ets，必须写成 ArkTS 子集（无 as const / typeof 查询 /
 * 索引访问类型 / 内联对象类型 / 数组展开）。
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
  SimilarNeighbor,
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

/**
 * 条目详情响应。
 *
 * 完整条目（ADR-024 修正了 ADR-010 的边界：文字可以在服务端，**只有图片二进制**
 * 属于端侧专属）。因此这里是完整的 HeritageItem，图片字段只是描述符（含授权信息），
 * 不包含二进制。
 */
export type ItemDetailResponse = HeritageItem

/** 关联推荐 */
export interface RelatedResponse {
  readonly itemId: string
  readonly related: readonly SimilarNeighbor[]
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
  /**
   * 是否启用重排精排（默认开启）。
   *
   * 精排会多一次网络往返（约 200-500ms）与一次计费。客户端在
   * 「边输入边搜」这类场景可以关掉，等到用户停下再开。
   */
  readonly rerank?: boolean
}

/** 检索命中来源 */
export type SearchChannel = 'keyword' | 'vector' | 'both'

export interface SearchHit {
  readonly itemId: string
  readonly name: string
  readonly section: Section
  /** 高亮片段 */
  readonly snippet: string
  /**
   * 相关度分数。**只在同一次响应内可比**，不要跨响应或跨查询比较。
   *
   * 量纲取决于管线阶段：
   *   - 启用精排且成功：精排相关度（0~1），最直观
   *   - 单通道未精排：该通道的原始分数（BM25 无上界 / 余弦 0~1）
   *   - 双通道未精排：RRF 融合分（约 0.01~0.05）
   *
   * 之所以不强行归一化：每种量纲的绝对值本身都有用（单通道时看绝对值就能判断
   * 命中强弱），统一归一化反而会抹掉这个信息。**排序始终可信，数值仅供参考。**
   */
  readonly score: number
  readonly channel: SearchChannel
  /** 语义命中时给出的可解释理由 */
  readonly reason?: string
}

/**
 * 查询理解结果：从自然语言查询里识别出的结构化条件。
 *
 * 回传给客户端是为了**可观测** —— UI 上可以显示「已识别：洛阳 · 汉唐 · 窑址」，
 * 让用户知道系统为什么这样筛，也让路演演示时能直观展示理解能力。
 */
export interface QueryUnderstanding {
  readonly cities: readonly City[]
  readonly eras: readonly Era[]
  readonly types: readonly HeritageType[]
  /** 命中的专名（条目名 / 别名 / 文物 / 人物 / 关键词） */
  readonly entities: readonly string[]
  /** 命中的条目 id，供「猜你在找」与图谱增强使用 */
  readonly matchedItems: readonly string[]
}

export interface SearchResponse {
  readonly hits: readonly SearchHit[]
  readonly tookMs: number
  /** 是否触发了降级（true 表示语义通道不可用，仅关键词） */
  readonly degraded: boolean
  /** 实际参与检索的通道 */
  readonly channels: readonly SearchChannel[]
  /** 查询理解结果 */
  readonly understanding?: QueryUnderstanding
  /**
   * 是否放宽了筛选。
   *
   * 从查询里推断出的条件过严时（例：「洛阳的唐代窑址」而洛阳没有窑址），
   * 首次检索会是零结果；此时自动去掉**推断的**条件重检一次并置此标志。
   * 用户在界面上显式选择的筛选不会被放宽。
   */
  readonly relaxed?: boolean
  /** 是否实际做了重排精排（请求了但失败时为 false） */
  readonly reranked?: boolean
}

// ---------------------------------------------------------------------------
// 用量统计
// ---------------------------------------------------------------------------

/** 单个操作的用量 */
export interface UsageStatsEntry {
  readonly operation: string
  readonly callCount: number
  readonly tokens: number
  readonly totalMs: number
  readonly errorCount: number
}

/**
 * 用量统计。
 *
 * 存在的意义是**成本可观测**：路演前能确认「演示一轮大概烧多少钱」，
 * 出了异常也能从 errorCount 第一时间发现。
 */
export interface UsageStatsResponse {
  /** 统计起始时间（毫秒时间戳） */
  readonly since: number
  readonly totalCalls: number
  readonly totalTokens: number
  readonly totalMs: number
  readonly errorRate: number
  readonly byOperation: readonly UsageStatsEntry[]
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

/** 图谱路径（问答证据） */
export interface GraphPath {
  readonly from: string
  readonly fromName: string
  readonly rel: GraphRelation
  readonly to: string
  readonly toName: string
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

export interface MsgError {
  readonly type: 'error'
  readonly code: string
  readonly message: string
}

export type QaClientMessage = QaAsk
export type QaServerMessage = QaAck | QaDelta | QaDone | MsgError

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

/** 一条完整路径（多跳） */
export type GraphPathChain = GraphPath[]

export interface GraphPathResponse {
  readonly paths: readonly GraphPathChain[]
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
  readonly table: string
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
  /**
   * 上次同步游标 —— **服务器单调序号，不是时间戳**。
   *
   * 为什么不用时间戳：若客户端游标是 T、而一条新变更的服务器时间戳也恰好是 T，
   * 下次拉取用 `> T` 会把它永久漏掉（同毫秒内的变更尤其容易触发）。
   * 单调序号没有这个问题：它只在有变更时递增，且严格可比较。
   * 服务器时间只用于展示，不参与游标运算。
   */
  readonly since: number
}

export interface SyncProgressMsg {
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
  /** 本次拉取后的新游标，客户端应存下并用于下次 pull */
  readonly cursor: number
  /** 服务器时间，仅供展示，不参与游标运算 */
  readonly serverTime: number
}

export interface SyncStateMessage {
  readonly type: 'state'
  readonly state: SyncState
}

export type SyncClientMessage = SyncPush | SyncPull
export type SyncServerMessage =
  | SyncProgressMsg
  | SyncApplied
  | SyncPulled
  | SyncStateMessage
  | MsgError

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

/** 按 provider:operation 聚合的单条用量，如 dashscope:embedding */
export interface OperationUsage {
  readonly operation: string
  readonly usage: UsageEntry
}

export interface UsageStats {
  readonly byOperation: readonly OperationUsage[]
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
// 收藏（REST 备选通道，主通道为同步）
// ---------------------------------------------------------------------------

export interface CollectRequest {
  readonly targetType: CollectTargetType
  readonly targetId: string
  readonly tagIds?: readonly string[]
}
