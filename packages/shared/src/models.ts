/**
 * 数据模型。
 *
 * 本文件为纯接口定义，会被 tools/gen 生成为端侧 .ets，
 * 因此只放数据结构，不放逻辑。
 */

import type { City, CollectTargetType, Era, HeritageType, Level, Section, SyncState } from './constants'

// ---------------------------------------------------------------------------
// 档案条目
// ---------------------------------------------------------------------------

/** 历史事件 */
export interface HeritageEvent {
  /** 年份，可为"公元前 1750 年"这类表述 */
  readonly year: string
  readonly title: string
  readonly desc: string
}

/** 相关诗词 */
export interface HeritagePoem {
  readonly title: string
  readonly author: string
  readonly dynasty: string
  readonly content: string
  /** 若该诗词并非本遗址直接关联（如取自同城同题材），在此说明 */
  readonly note?: string
}

/** 现代文旅信息 */
export interface TravelInfo {
  readonly hours?: string
  readonly ticket?: string
  /** 最佳游览季节 */
  readonly best?: string
  readonly tips: readonly string[]
}

/** 文物（可被单独收藏的"轻条目"） */
export interface Artifact {
  /** 全局唯一，格式 <itemId>#<序号> */
  readonly id: string
  readonly name: string
  readonly desc: string
  readonly museum?: string
}

/** 相关人物 */
export interface HeritageFigure {
  readonly name: string
  readonly role: string
  readonly desc: string
}

/** 配图（credit 与 license 必填） */
export interface HeritageImage {
  /** 相对 rawfile 的路径，如 img/ly-erlitou-1.webp */
  readonly url: string
  readonly caption: string
  readonly credit: string
  readonly license: string
}

/** 资料来源 */
export interface SourceRef {
  readonly title: string
  readonly url: string
  /** 访问日期，ISO 格式 yyyy-MM-dd */
  readonly accessedAt: string
}

/**
 * 一处地点型文化遗产的完整档案（五层内容）。
 * 字段顺序与详情页 Tab 顺序一致。
 */
export interface HeritageItem {
  /** 全局唯一，格式 <城市前缀>-<拼音>，如 ly-erlitou */
  readonly id: string
  readonly name: string
  readonly aliases: readonly string[]

  // ---- 三维度 ----
  readonly city: City
  readonly era: Era
  /** 起止年代，负数表示公元前；元组本身需可变以与校验层一致 */
  readonly eraRange?: [number, number]
  readonly types: readonly HeritageType[]
  readonly level?: Level

  readonly geo: { readonly lat: number; readonly lng: number }

  // ---- 五层内容 ----
  /** 一句话概述 */
  readonly summary: string
  /** 图文介绍，300-800 字 */
  readonly intro: string
  /** 考古发现，200-600 字 */
  readonly archaeology: string
  readonly events: readonly HeritageEvent[]
  readonly poems: readonly HeritagePoem[]
  readonly travel?: TravelInfo
  readonly artifacts: readonly Artifact[]
  readonly figures: readonly HeritageFigure[]
  readonly images: readonly HeritageImage[]

  // ---- 检索与溯源 ----
  readonly keywords: readonly string[]
  readonly sources: readonly SourceRef[]
}

// ---------------------------------------------------------------------------
// 检索与图谱
// ---------------------------------------------------------------------------

/** 详情页的六个内容分区已定义在 constants.ts 的 SECTIONS */

/** 检索片段（chunk） */
export interface Chunk {
  readonly id: string
  readonly itemId: string
  readonly section: Section
  /** 该条目内的序号 */
  readonly seq: number
  readonly text: string
  /** 构建期注入的 jieba 分词结果，供端侧检索 */
  readonly tokens: readonly string[]
}

export const GRAPH_NODE_TYPES = [
  'Site',
  'Era',
  'City',
  'Type',
  'Artifact',
  'Figure',
  'Event',
  'Poem',
  'Theme',
  'Museum',
] as const

export type GraphNodeType = (typeof GRAPH_NODE_TYPES)[number]

/** 图谱节点 */
export interface GraphNode {
  readonly id: string
  readonly type: GraphNodeType
  readonly name: string
  readonly aliases: readonly string[]
  /** PageRank 值，构建期计算，用于可视化节点大小与推荐排序 */
  readonly rank?: number
}

/** 图谱关系 */
export const GRAPH_RELATIONS = [
  'locatedIn',
  'belongsToEra',
  'hasType',
  'unearthed',
  'relatedFigure',
  'hasPoem',
  'occurredEvent',
  'culturalLink',
  'nearby',
  'collectedAt',
] as const

export type GraphRelation = (typeof GRAPH_RELATIONS)[number]

/** 图谱边 */
export interface GraphEdge {
  readonly id: string
  readonly from: string
  readonly to: string
  readonly rel: GraphRelation
  readonly weight: number
  /** 关系依据（用于问答时的证据展示） */
  readonly evidence?: string
}

/** 预计算的关联推荐条目 */
export interface SimilarEntry {
  readonly itemId: string
  /** 相似邻居，按相似度降序 */
  readonly neighbors: readonly { readonly id: string; readonly score: number; readonly reason: string }[]
}

// ---------------------------------------------------------------------------
// 个人数据
// ---------------------------------------------------------------------------

/** 所有可同步记录的共同字段 */
export interface SyncableRecord {
  readonly id: string
  /** 毫秒时间戳，冲突时以最新为准（LWW） */
  readonly updatedAt: number
  readonly createdAt: number
  /** 产生该记录最后修改的设备标识 */
  readonly deviceId: string
  /** 软删除标记，保证删除操作也能同步 */
  readonly deleted: boolean
}

/** 收藏 */
export interface Favorite extends SyncableRecord {
  readonly targetType: CollectTargetType
  /** site 为 itemId；artifact 为 artifactId */
  readonly targetId: string
  readonly tagIds: readonly string[]
}

/** 笔记 */
export interface Note extends SyncableRecord {
  readonly targetType: CollectTargetType
  readonly targetId: string
  readonly content: string
}

/** 标签 */
export interface Tag extends SyncableRecord {
  readonly name: string
  /** 是否为预设标签（预设标签不可删除） */
  readonly preset: boolean
}

/** 用户自建主题（用于个人知识图谱） */
export interface Theme extends SyncableRecord {
  readonly name: string
  /** 归入该主题的条目 ID（遗址或文物） */
  readonly targetIds: readonly string[]
}

/** 学习进度：按时代分段的完成情况 */
export interface Progress {
  readonly era: string
  readonly visited: number
  readonly total: number
}

/** 冲突记录（同步中心展示用） */
export interface ConflictRecord {
  readonly id: string
  readonly recordId: string
  readonly table: string
  readonly localUpdatedAt: number
  readonly remoteUpdatedAt: number
  readonly winner: 'local' | 'remote'
  readonly detectedAt: number
}

/** 同步状态（同步中心面板数据源） */
export interface SyncStatus {
  readonly state: SyncState
  /** 最后同步完成时间（毫秒时间戳） */
  readonly lastSyncAt: number
  /** 待推送条数 */
  readonly pending: number
  /** 本次同步进度 */
  readonly progress: { readonly done: number; readonly total: number }
  /** 同步方向标识，如「手机 → 平板」 */
  readonly direction: string
  /** 冲突条数 */
  readonly conflicts: number
}

// ---------------------------------------------------------------------------
// 问答引用
// ---------------------------------------------------------------------------

/** 回答中引用的资料片段，点击可跳转至对应条目详情 */
export interface Citation {
  readonly chunkId: string
  readonly itemId: string
  /** 展示标题，如「黄冶三彩窑址 · 考古发现」 */
  readonly title: string
  /** 引用到的原文片段 */
  readonly snippet: string
  /** 该条目内的分区 */
  readonly section: Section
}
