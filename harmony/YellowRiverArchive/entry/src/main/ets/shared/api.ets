/**
 * 本文件由 tools/gen 自动生成，请勿手改。
 * 源文件：packages/shared/src/api.ts
 * 重新生成：pnpm gen:arkts
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
  readonly types: HeritageType[]
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
  readonly items: HeritageSummary[]
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
  readonly related: SimilarNeighbor[]
}

// ---------------------------------------------------------------------------
// 检索
// ---------------------------------------------------------------------------

export interface SearchFilters {
  readonly cities?: City[]
  readonly eras?: Era[]
  readonly types?: HeritageType[]
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
  /**
   * 相关度分数。**只在同一次响应内可比**，不要跨响应或跨查询比较。
   *
   * 量纲随通道数变化：单通道时是该通道的原始分数（BM25 无上界 / 余弦在 [0,1]），
   * 双通道时是 RRF 融合分（约 0.01~0.05）。之所以不统一，是因为两种场景下
   * 「分数量级」本身都有用 —— 单通道时光看绝对值就能判断命中强弱，
   * 强行归一化反而会把这个信息抹掉。**排序始终可信，数值仅供展示参考。**
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
  readonly cities: City[]
  readonly eras: Era[]
  readonly types: HeritageType[]
  /** 命中的专名（条目名 / 别名 / 文物 / 人物 / 关键词） */
  readonly entities: string[]
  /** 命中的条目 id，供「猜你在找」与图谱增强使用 */
  readonly matchedItems: string[]
}

export interface SearchResponse {
  readonly hits: SearchHit[]
  readonly tookMs: number
  /** 是否触发了降级（true 表示语义通道不可用，仅关键词） */
  readonly degraded: boolean
  /** 实际参与检索的通道 */
  readonly channels: SearchChannel[]
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
  readonly citations: Citation[]
  readonly graphPaths: GraphPath[]
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
  readonly nodeTypes?: string[]
}

export interface SubgraphResponse {
  readonly nodes: GraphNode[]
  readonly edges: GraphEdge[]
}

export interface GraphSearchResponse {
  readonly nodes: GraphNode[]
}

export interface GraphPathQuery {
  readonly from: string
  readonly to: string
}

/** 一条完整路径（多跳） */
export type GraphPathChain = GraphPath[]

export interface GraphPathResponse {
  readonly paths: GraphPathChain[]
}

/** 社区（自动发现的文化主题） */
export interface Community {
  readonly id: string
  readonly name: string
  readonly nodeIds: string[]
  /** 社区规模，用于可视化 */
  readonly size: number
}

export interface CommunitiesResponse {
  readonly communities: Community[]
}

/** 由用户收藏生成个人主题子图 */
export interface ThemeBuildRequest {
  readonly name: string
  readonly targetIds: string[]
}

export interface ThemeBuildResponse {
  readonly theme: Theme
  readonly nodes: GraphNode[]
  readonly edges: GraphEdge[]
  /** 算法推荐的拓展条目 */
  readonly suggestions: string[]
}

// ---------------------------------------------------------------------------
// 同步（WebSocket）
// ---------------------------------------------------------------------------

/** 单表变更集 */
export interface ChangeSet {
  readonly table: string
  readonly records: SyncableRecord[]
}

export interface SyncPush {
  readonly type: 'push'
  readonly deviceId: string
  readonly changes: ChangeSet[]
}

export interface SyncPull {
  readonly type: 'pull'
  readonly deviceId: string
  /** 上次同步游标（毫秒时间戳） */
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
  readonly conflicts: ConflictRecord[]
}

export interface SyncPulled {
  readonly type: 'pulled'
  readonly changes: ChangeSet[]
  readonly conflicts: ConflictRecord[]
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
  readonly favorites: Favorite[]
  readonly notes: Note[]
  readonly tags: Tag[]
  readonly themes: Theme[]
}

export interface ImportResult {
  readonly imported: number
  readonly merged: number
  readonly conflicts: ConflictRecord[]
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
  readonly byOperation: OperationUsage[]
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
  readonly tagIds?: string[]
}
