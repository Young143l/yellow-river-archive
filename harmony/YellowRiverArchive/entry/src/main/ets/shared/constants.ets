/**
 * 本文件由 tools/gen 自动生成，请勿手改。
 * 源文件：packages/shared/src/constants.ts
 * 重新生成：pnpm gen:arkts
 */
// ---------------------------------------------------------------------------
// 城市
// ---------------------------------------------------------------------------

/** 赛题指定的沿黄五市 */
export type City = '三门峡' | '洛阳' | '郑州' | '开封' | '濮阳'

export const CITIES: City[] = ['三门峡', '洛阳', '郑州', '开封', '濮阳']

/** 城市元信息：ID 前缀与档案配额（配额依据 ADR-014） */
export interface CityMeta {
  readonly name: City
  /** 条目 ID 前缀，如 ly-erlitou */
  readonly idPrefix: string
  /** 该市档案条数配额 */
  readonly quota: number
}

export const CITY_META: CityMeta[] = [
  { name: '洛阳', idPrefix: 'ly', quota: 20 },
  { name: '郑州', idPrefix: 'zz', quota: 20 },
  { name: '开封', idPrefix: 'kf', quota: 16 },
  { name: '三门峡', idPrefix: 'sms', quota: 14 },
  { name: '濮阳', idPrefix: 'py', quota: 10 },
]

/** 档案总条数 */
export const TOTAL_QUOTA: number = 80

// ---------------------------------------------------------------------------
// 时代
// ---------------------------------------------------------------------------

/** 赛题时代轴六段（顺序即时间轴顺序） */
export type CoreEra = '仰韶' | '龙山' | '夏商' | '周' | '汉唐' | '宋'

/** 完整时代集合（含"宋以后"延伸段，UI 上弱化展示） */
export type Era = CoreEra | '宋以后'

export const CORE_ERAS: CoreEra[] = ['仰韶', '龙山', '夏商', '周', '汉唐', '宋']

export const ERAS: Era[] = ['仰韶', '龙山', '夏商', '周', '汉唐', '宋', '宋以后']

// ---------------------------------------------------------------------------
// 遗产类型
// ---------------------------------------------------------------------------

export type HeritageType =
  | '都城遗址'
  | '城址'
  | '聚落遗址'
  | '墓葬群'
  | '窑址'
  | '古建筑'
  | '石窟寺'
  | '碑刻'
  | '祭祀址'
  | '关隘遗址'

export const HERITAGE_TYPES: HeritageType[] = [
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
]

/** 赛题点名的四类，每类条目数不得少于 6（见数据规范） */
export const REQUIRED_TYPES: HeritageType[] = ['都城遗址', '墓葬群', '窑址', '古建筑']

// ---------------------------------------------------------------------------
// 详情页分区
// ---------------------------------------------------------------------------

/** 详情页六个内容分区，顺序与 Tab 顺序一致 */
export type Section = 'intro' | 'archaeology' | 'events' | 'poems' | 'travel' | 'graph'

export const SECTIONS: Section[] = ['intro', 'archaeology', 'events', 'poems', 'travel', 'graph']

/** 分区与中文名的对应项（用数组而非 Record，便于 ArkTS 消费） */
export interface SectionLabel {
  readonly key: Section
  readonly label: string
}

export const SECTION_LABELS: SectionLabel[] = [
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

export type Level = '世界遗产' | '全国重点文保' | '省级文保' | '市县级文保' | '未定级'

export const LEVELS: Level[] = ['世界遗产', '全国重点文保', '省级文保', '市县级文保', '未定级']

// ---------------------------------------------------------------------------
// 个人数据
// ---------------------------------------------------------------------------

/** 收藏 / 笔记的指向类型：遗址条目或文物条目 */
export type CollectTargetType = 'site' | 'artifact'

export const COLLECT_TARGET_TYPES: CollectTargetType[] = ['site', 'artifact']

/** 预设标签（用户可另建自定义标签） */
export type PresetTag = '待实地探访' | '已去过' | '研究资料'

export const PRESET_TAGS: PresetTag[] = ['待实地探访', '已去过', '研究资料']

/** 同步状态 */
export type SyncState = 'idle' | 'syncing' | 'offline' | 'error'

export const SYNC_STATES: SyncState[] = ['idle', 'syncing', 'offline', 'error']

// ---------------------------------------------------------------------------
// 错误码
// ---------------------------------------------------------------------------

/** E1xxx 端侧 ｜ E2xxx 云侧 ｜ E3xxx 数据 */
export type ErrorCode =
  | 'E1001'
  | 'E1002'
  | 'E1003'
  | 'E1004'
  | 'E1005'
  | 'E2001'
  | 'E2002'
  | 'E2003'
  | 'E2004'
  | 'E3001'
  | 'E3002'
  | 'E3003'
  | 'E3004'

export interface ErrorCodeMap {
  readonly DATA_IMPORT_FAILED: ErrorCode
  readonly SEARCH_FAILED: ErrorCode
  readonly SYNC_FAILED: ErrorCode
  readonly IDENTITY_BIND_FAILED: ErrorCode
  readonly GRAPH_RENDER_FAILED: ErrorCode
  readonly EMBEDDING_UNAVAILABLE: ErrorCode
  readonly RERANK_UNAVAILABLE: ErrorCode
  readonly LLM_UNAVAILABLE: ErrorCode
  readonly SEARCH_TIMEOUT: ErrorCode
  readonly SCHEMA_INVALID: ErrorCode
  readonly DUPLICATE_TEXT: ErrorCode
  readonly LICENSE_MISSING: ErrorCode
  readonly COVERAGE_INSUFFICIENT: ErrorCode
}

export const ERROR_CODES: ErrorCodeMap = {
  DATA_IMPORT_FAILED: 'E1001',
  SEARCH_FAILED: 'E1002',
  SYNC_FAILED: 'E1003',
  IDENTITY_BIND_FAILED: 'E1004',
  GRAPH_RENDER_FAILED: 'E1005',
  EMBEDDING_UNAVAILABLE: 'E2001',
  RERANK_UNAVAILABLE: 'E2002',
  LLM_UNAVAILABLE: 'E2003',
  SEARCH_TIMEOUT: 'E2004',
  SCHEMA_INVALID: 'E3001',
  DUPLICATE_TEXT: 'E3002',
  LICENSE_MISSING: 'E3003',
  COVERAGE_INSUFFICIENT: 'E3004',
}
