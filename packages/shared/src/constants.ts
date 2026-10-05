/**
 * 全局常量与枚举。
 *
 * 本文件为纯类型与常量，不依赖任何第三方库，会被 tools/gen 生成为端侧 .ets，
 * 因此只能使用 ArkTS 也支持的基础语法（不要引入泛型体操、映射类型等）。
 */

// ---------------------------------------------------------------------------
// 城市
// ---------------------------------------------------------------------------

/** 赛题指定的沿黄五市 */
export const CITIES = ['三门峡', '洛阳', '郑州', '开封', '濮阳'] as const

export type City = (typeof CITIES)[number]

/** 城市元信息：ID 前缀与档案配额（配额依据 ADR-014） */
export interface CityMeta {
  readonly name: City
  /** 条目 ID 前缀，如 ly-erlitou */
  readonly idPrefix: string
  /** 该市档案条数配额 */
  readonly quota: number
}

export const CITY_META: readonly CityMeta[] = [
  { name: '洛阳', idPrefix: 'ly', quota: 20 },
  { name: '郑州', idPrefix: 'zz', quota: 20 },
  { name: '开封', idPrefix: 'kf', quota: 16 },
  { name: '三门峡', idPrefix: 'sms', quota: 14 },
  { name: '濮阳', idPrefix: 'py', quota: 10 },
]

/** 档案总条数 */
export const TOTAL_QUOTA = 80

// ---------------------------------------------------------------------------
// 时代
// ---------------------------------------------------------------------------

/** 赛题时代轴六段（顺序即时间轴顺序） */
export const CORE_ERAS = ['仰韶', '龙山', '夏商', '周', '汉唐', '宋'] as const

/** 完整时代集合（含"宋以后"延伸段，UI 上弱化展示） */
export const ERAS = [...CORE_ERAS, '宋以后'] as const

export type Era = (typeof ERAS)[number]

// ---------------------------------------------------------------------------
// 遗产类型
// ---------------------------------------------------------------------------

export const HERITAGE_TYPES = [
  '都城遗址',
  '城址',
  '聚落遗址',
  '墓葬群',
  '窑址',
  '古建筑',
  '石窟寺',
  '碑刻',
  '祭祀址',
  '关隘遗址',
] as const

export type HeritageType = (typeof HERITAGE_TYPES)[number]

/** 赛题点名的四类，每类条目数不得少于 6（见数据规范） */
export const REQUIRED_TYPES = ['都城遗址', '墓葬群', '窑址', '古建筑'] as const

// ---------------------------------------------------------------------------
// 详情页分区
// ---------------------------------------------------------------------------

/** 详情页六个内容分区，顺序与 Tab 顺序一致 */
export const SECTIONS = ['intro', 'archaeology', 'events', 'poems', 'travel', 'graph'] as const

export type Section = (typeof SECTIONS)[number]

/** 分区与中文名的对应项（用数组而非 Record，便于 ArkTS 消费） */
export interface SectionLabel {
  readonly key: Section
  readonly label: string
}

export const SECTION_LABELS: readonly SectionLabel[] = [
  { key: 'intro', label: '图文介绍' },
  { key: 'archaeology', label: '考古发现' },
  { key: 'events', label: '历史事件' },
  { key: 'poems', label: '相关诗词' },
  { key: 'travel', label: '文旅信息' },
  { key: 'graph', label: '关联图谱' },
]

// ---------------------------------------------------------------------------
// 保护级别
// ---------------------------------------------------------------------------

export const LEVELS = ['世界遗产', '全国重点文保', '省级文保', '市县级文保', '未定级'] as const

export type Level = (typeof LEVELS)[number]

// ---------------------------------------------------------------------------
// 个人数据
// ---------------------------------------------------------------------------

/** 收藏 / 笔记的指向类型：遗址条目或文物条目 */
export const COLLECT_TARGET_TYPES = ['site', 'artifact'] as const

export type CollectTargetType = (typeof COLLECT_TARGET_TYPES)[number]

/** 预设标签（用户可另建自定义标签） */
export const PRESET_TAGS = ['待实地探访', '已去过', '研究资料'] as const

export type PresetTag = (typeof PRESET_TAGS)[number]

/** 同步状态 */
export const SYNC_STATES = ['idle', 'syncing', 'offline', 'error'] as const

export type SyncState = (typeof SYNC_STATES)[number]

// ---------------------------------------------------------------------------
// 错误码
// ---------------------------------------------------------------------------

/** E1xxx 端侧 ｜ E2xxx 云侧 ｜ E3xxx 数据 */
export const ERROR_CODES = {
  // 端侧
  DATA_IMPORT_FAILED: 'E1001',
  SEARCH_FAILED: 'E1002',
  SYNC_FAILED: 'E1003',
  IDENTITY_BIND_FAILED: 'E1004',
  GRAPH_RENDER_FAILED: 'E1005',
  // 云侧
  EMBEDDING_UNAVAILABLE: 'E2001',
  RERANK_UNAVAILABLE: 'E2002',
  LLM_UNAVAILABLE: 'E2003',
  SEARCH_TIMEOUT: 'E2004',
  // 数据
  SCHEMA_INVALID: 'E3001',
  DUPLICATE_TEXT: 'E3002',
  LICENSE_MISSING: 'E3003',
  COVERAGE_INSUFFICIENT: 'E3004',
} as const

export type ErrorCode = (typeof ERROR_CODES)[keyof typeof ERROR_CODES]
