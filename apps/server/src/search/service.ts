/**
 * 检索服务：查询理解 → 双通道召回 → RRF 融合 → 实体加权。
 *
 * 通道分工：
 *   - 关键词通道（BM25 / FTS5）：专名精确，纯本地，永不失败
 *   - 语义通道（百炼嵌入 + 点积）：语义召回，走网络，可能降级
 *
 * 融合用 RRF 而非加权求和：BM25 分数无上界、余弦在 [-1,1]，量纲不可比，
 * 直接加权需要拍一个没有依据的系数。RRF 只融合排名位次，无需标定。
 *
 * 分数约定：**score 只在同一次响应内可比**。单通道时是原始分数，
 * 多通道时是 RRF 分数（量级 ~0.01）。客户端不应依赖绝对数值。
 */

import type { EmbeddingProvider } from '@yra/ai'
import type { QueryUnderstanding, SearchChannel, SearchHit, SearchRequest, SearchResponse } from '@yra/shared'
import type { Tokenizer } from '@yra/nlp'

import type { Db } from '../db/index'
import { searchBm25, type SearchFilter } from './bm25'
import type { EntityDictionary } from './query-understanding'
import { understandQuery } from './query-understanding'
import { makeSnippet } from './snippet'
import { VectorChannel } from './vector-channel'
import type { VectorStore } from './vectors'

interface ChunkMeta {
  readonly chunkId: string
  readonly itemId: string
  readonly name: string
  readonly section: SearchHit['section']
  readonly text: string
}

export interface SearchDeps {
  readonly db: Db
  readonly vectors: VectorStore
  readonly tokenizer: Tokenizer
  readonly dict: EntityDictionary
  readonly vectorChannel: VectorChannel
}

/** 单通道的召回结果 */
interface ChannelResult {
  readonly channel: SearchChannel
  readonly ranked: readonly { chunkId: string; score: number }[]
}

/**
 * RRF 融合的 k 值。
 *
 * k=60 是论文给的常用值：它决定"排名前三的差距被抹平多少"。
 * k 越大各通道排名影响越平均，k 越小头部名次越重要。
 */
const RRF_K: number = 60

/**
 * 命中条目名/别名的加权系数。
 *
 * 用户直接报出条目名（「二里头」）时，该条目的内容理应排前 ——
 * 但两个通道都只看局部特征，短的事件段可能因为把名字重复了两遍而反超。
 * 1.5 是在「明显提权」与「不至于压掉所有其他结果」之间的折中。
 */
const ENTITY_BOOST: number = 1.5

function loadChunkMeta(db: Db, chunkIds: readonly string[]): Map<string, ChunkMeta> {
  if (chunkIds.length === 0) {
    return new Map<string, ChunkMeta>()
  }
  const placeholders: string = chunkIds.map(() => '?').join(',')
  const rows = db
    .prepare(
      `SELECT c.id AS chunkId, c.item_id AS itemId, c.section AS section, c.text AS text, i.name AS name
         FROM chunks c
         JOIN items i ON i.id = c.item_id
        WHERE c.id IN (${placeholders})`
    )
    .all(...chunkIds) as unknown as ChunkMeta[]

  const map = new Map<string, ChunkMeta>()
  for (const row of rows) {
    map.set(row.chunkId, row)
  }
  return map
}

/**
 * 求出筛选命中的全部片段 id。
 *
 * 为什么需要：向量通道是内存里的暴力检索，**不走 SQL**，筛选条件对它无效。
 * 必须先把允许的片段集算出来再交给它，否则语义通道会绕过用户筛选。
 */
function allowedChunkIds(db: Db, filter: SearchFilter): Set<string> | undefined {
  const conditions: string[] = []
  const args: string[] = []

  if (filter.cities !== undefined && filter.cities.length > 0) {
    conditions.push(`i.city IN (${filter.cities.map(() => '?').join(',')})`)
    args.push(...filter.cities)
  }
  if (filter.eras !== undefined && filter.eras.length > 0) {
    conditions.push(`i.era IN (${filter.eras.map(() => '?').join(',')})`)
    args.push(...filter.eras)
  }
  if (filter.types !== undefined && filter.types.length > 0) {
    const parts: string[] = []
    for (const type of filter.types) {
      parts.push('i.types LIKE ?')
      args.push(`%"${type}"%`)
    }
    conditions.push(`(${parts.join(' OR ')})`)
  }

  if (conditions.length === 0) {
    return undefined
  }

  const rows = db
    .prepare(`SELECT c.id AS id FROM chunks c JOIN items i ON i.id = c.item_id WHERE ${conditions.join(' AND ')}`)
    .all(...args) as unknown as { id: string }[]

  return new Set<string>(rows.map((r) => r.id))
}

function explicitFilter(request: SearchRequest): SearchFilter {
  const f = request.filters
  if (f === undefined) {
    return {}
  }
  return {
    ...(f.cities !== undefined && f.cities.length > 0 ? { cities: f.cities } : {}),
    ...(f.eras !== undefined && f.eras.length > 0 ? { eras: f.eras } : {}),
    ...(f.types !== undefined && f.types.length > 0 ? { types: f.types } : {}),
  }
}

function hasAnyFilter(filter: SearchFilter | undefined): boolean {
  if (filter === undefined) {
    return false
  }
  return (
    (filter.cities?.length ?? 0) > 0 || (filter.eras?.length ?? 0) > 0 || (filter.types?.length ?? 0) > 0
  )
}

/**
 * 合并筛选：**显式条件优先，推断只填空缺维度**。
 *
 * 用户在界面上勾了「郑州」、查询里又写了「洛阳」时，以界面为准 ——
 * 界面选择是明确动作，查询文本的推断只是猜测。
 * 两者作用于不同维度时则叠加（勾了「郑州」+ 输入「唐代」→ 郑州 ∩ 汉唐）。
 */
function mergeFilter(explicit: SearchFilter, inferred: SearchFilter): SearchFilter {
  const pick = <T>(e: readonly T[] | undefined, i: readonly T[] | undefined): readonly T[] | undefined =>
    e !== undefined && e.length > 0 ? e : i

  const cities = pick(explicit.cities, inferred.cities)
  const eras = pick(explicit.eras, inferred.eras)
  const types = pick(explicit.types, inferred.types)

  return {
    ...(cities !== undefined ? { cities } : {}),
    ...(eras !== undefined ? { eras } : {}),
    ...(types !== undefined ? { types } : {}),
  }
}

interface FusionResult {
  readonly ranked: { chunkId: string; score: number; channels: SearchChannel[] }[]
  readonly used: SearchChannel[]
}

/**
 * 融合多通道结果。
 *
 * 单通道时直接用原始分数：RRF 只保留名次、丢掉分数量级，
 * 而分数量级对前端展示与「是否算命中」的阈值判断都有用，没敌人时不该丢。
 */
function fuse(channels: readonly ChannelResult[], topK: number): FusionResult {
  const usable: ChannelResult[] = channels.filter((c) => c.ranked.length > 0)
  if (usable.length === 0) {
    return { ranked: [], used: [] }
  }

  if (usable.length === 1) {
    const only: ChannelResult | undefined = usable[0]
    return {
      ranked: (only?.ranked ?? []).slice(0, topK).map((h) => ({ ...h, channels: [only?.channel ?? 'keyword'] })),
      used: only !== undefined ? [only.channel] : [],
    }
  }

  const scores = new Map<string, number>()
  const contributors = new Map<string, SearchChannel[]>()
  for (const channel of usable) {
    channel.ranked.forEach((hit, rank) => {
      scores.set(hit.chunkId, (scores.get(hit.chunkId) ?? 0) + 1 / (RRF_K + rank + 1))
      const list: SearchChannel[] = contributors.get(hit.chunkId) ?? []
      if (!list.includes(channel.channel)) {
        list.push(channel.channel)
      }
      contributors.set(hit.chunkId, list)
    })
  }

  const ranked = [...scores.entries()]
    .map(([chunkId, score]) => ({
      chunkId,
      score,
      channels: contributors.get(chunkId) ?? [],
    }))
    .sort((a, b) => b.score - a.score)
    .slice(0, topK)

  return { ranked, used: usable.map((c) => c.channel) }
}

interface RoundResult {
  readonly fusion: FusionResult
  readonly degraded: boolean
  readonly vectorError?: string
  readonly vectorCached: boolean
}

/** 跑一轮双通道并融合 */
async function runOnce(
  deps: SearchDeps,
  query: string,
  tokens: readonly string[],
  topK: number,
  filter: SearchFilter
): Promise<RoundResult> {
  const allow: Set<string> | undefined = allowedChunkIds(deps.db, filter)

  // 关键词通道同步、语义通道异步，并发发起
  const keyword: ChannelResult = {
    channel: 'keyword',
    ranked: searchBm25(deps.db, tokens, topK * 3, filter),
  }
  const vector = await deps.vectorChannel.search(query, topK * 3, allow)

  const channels: ChannelResult[] = [keyword]
  if (vector.ok) {
    channels.push({ channel: 'vector', ranked: vector.ranked })
  }

  return {
    fusion: fuse(channels, topK),
    degraded: !vector.ok,
    ...(vector.error !== undefined ? { vectorError: vector.error } : {}),
    vectorCached: vector.cached,
  }
}

export async function search(deps: SearchDeps, request: SearchRequest): Promise<SearchResponse> {
  const started: number = Date.now()
  const topK: number = Math.max(1, Math.min(request.topK ?? 10, 50))

  const tokens: string[] = deps.tokenizer.tokenizeQuery(request.query)
  if (tokens.length === 0) {
    return { hits: [], tookMs: Date.now() - started, degraded: false, channels: [] }
  }

  // ---- 查询理解 ----
  const understanding: QueryUnderstanding = understandQuery(request.query, deps.dict)
  const inferred: SearchFilter = {
    ...(understanding.cities.length > 0 ? { cities: understanding.cities } : {}),
    ...(understanding.eras.length > 0 ? { eras: understanding.eras } : {}),
    ...(understanding.types.length > 0 ? { types: understanding.types } : {}),
  }
  const explicit: SearchFilter = explicitFilter(request)
  const merged: SearchFilter = mergeFilter(explicit, inferred)

  // ---- 首次检索（带全部条件）----
  let round: RoundResult = await runOnce(deps, request.query, tokens, topK, merged)
  let relaxed: boolean = false

  // ---- 过约束放宽 ----
  // 从查询文本推断的条件把结果压到零条时，去掉**推断的**条件重试一次。
  // 显式条件不放宽：用户自己勾的筛选应该被尊重，哪怕结果是空。
  if (round.fusion.ranked.length === 0 && hasAnyFilter(inferred)) {
    const retry: RoundResult = await runOnce(deps, request.query, tokens, topK, explicit)
    if (retry.fusion.ranked.length > 0) {
      round = retry
      relaxed = true
    }
  }

  // ---- 装配结果 + 实体加权 ----
  const ranked = round.fusion.ranked
  const meta: Map<string, ChunkMeta> = loadChunkMeta(
    deps.db,
    ranked.map((r) => r.chunkId)
  )
  const matched: ReadonlySet<string> = new Set<string>(understanding.matchedItems)

  const boosted = ranked
    .map((item) => {
      const info: ChunkMeta | undefined = meta.get(item.chunkId)
      const hitEntity: boolean = info !== undefined && matched.has(info.itemId)
      return { ...item, hitEntity, score: hitEntity ? item.score * ENTITY_BOOST : item.score }
    })
    .sort((a, b) => b.score - a.score)
    .slice(0, topK)

  const hits: SearchHit[] = []
  for (const item of boosted) {
    const info: ChunkMeta | undefined = meta.get(item.chunkId)
    if (info === undefined) {
      continue
    }
    const channel: SearchChannel =
      item.channels.length === 2 ? 'both' : (item.channels[0] ?? 'keyword')
    hits.push({
      itemId: info.itemId,
      name: info.name,
      section: info.section,
      snippet: makeSnippet(info.text, tokens),
      score: Math.round(item.score * 10000) / 10000,
      channel,
      ...(item.hitEntity ? { reason: '命中条目名' } : {}),
    })
  }

  return {
    hits,
    tookMs: Date.now() - started,
    degraded: round.degraded,
    channels: round.fusion.used,
    understanding,
    ...(relaxed ? { relaxed } : {}),
  }
}

/** 供路由层构造依赖（避免在路由里直接 new） */
export function createVectorChannel(provider: EmbeddingProvider, store: VectorStore): VectorChannel {
  return new VectorChannel({ provider, store })
}
