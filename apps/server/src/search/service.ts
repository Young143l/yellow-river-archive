/**
 * 检索服务：多通道召回 + 融合。
 *
 * 当前启用关键词通道（BM25）。语义通道与 RRF 融合在 D3-10 接入 ——
 * 这里已经按"多通道"的形状写好，届时只需实现一个 channel 函数。
 *
 * 融合策略：
 *   - 单通道：直接用原始分数排序（保留分数大小关系，便于前端展示与阈值判断）
 *   - 多通道：RRF（Reciprocal Rank Fusion）。不同通道的分数**量纲不可比**
 *     （BM25 无上界、余弦在 [-1,1]），所以只融合排名位次，不融合分数
 */

import type { SearchHit, SearchRequest, SearchResponse } from '@yra/shared'
import type { Tokenizer } from '@yra/nlp'

import type { Db } from '../db/index'
import { searchBm25, type SearchFilter } from './bm25'
import { makeSnippet } from './snippet'
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
}

/** 单通道的召回结果 */
interface ChannelResult {
  readonly channel: SearchHit['channel']
  readonly ranked: { chunkId: string; score: number }[]
}

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

function toFilter(request: SearchRequest): SearchFilter | undefined {
  const f = request.filters
  if (f === undefined) {
    return undefined
  }
  const hasAny: boolean =
    (f.cities?.length ?? 0) > 0 || (f.eras?.length ?? 0) > 0 || (f.types?.length ?? 0) > 0
  if (!hasAny) {
    return undefined
  }
  return {
    ...(f.cities !== undefined ? { cities: f.cities } : {}),
    ...(f.eras !== undefined ? { eras: f.eras } : {}),
    ...(f.types !== undefined ? { types: f.types } : {}),
  }
}

/** 关键词通道 */
function keywordChannel(
  deps: SearchDeps,
  tokens: readonly string[],
  topK: number,
  filter: SearchFilter | undefined
): ChannelResult {
  return {
    channel: 'keyword',
    ranked: searchBm25(deps.db, tokens, topK, filter),
  }
}

/**
 * RRF 融合。
 *
 * k=60 是论文给的常用值：它决定"排名前三的差距被抹平多少"。
 * k 越大，各通道的排名影响越平均；k 越小，头部名次越重要。
 */
const RRF_K: number = 60

function fuseRrf(channels: readonly ChannelResult[], topK: number): { chunkId: string; score: number }[] {
  const scores = new Map<string, number>()
  for (const channel of channels) {
    channel.ranked.forEach((hit, rank) => {
      const contribution: number = 1 / (RRF_K + rank + 1)
      scores.set(hit.chunkId, (scores.get(hit.chunkId) ?? 0) + contribution)
    })
  }
  return [...scores.entries()]
    .map(([chunkId, score]) => ({ chunkId, score }))
    .sort((a, b) => b.score - a.score)
    .slice(0, topK)
}

export function search(deps: SearchDeps, request: SearchRequest): SearchResponse {
  const started: number = Date.now()
  const topK: number = Math.max(1, Math.min(request.topK ?? 10, 50))
  const filter: SearchFilter | undefined = toFilter(request)

  const tokens: string[] = deps.tokenizer.tokenizeQuery(request.query)
  if (tokens.length === 0) {
    return { hits: [], tookMs: Date.now() - started, degraded: false, channels: [] }
  }

  const channels: ChannelResult[] = [keywordChannel(deps, tokens, topK * 3, filter)]

  // 单通道时直接用原始分数：RRF 只保留名次、丢掉分数量级，
  // 而分数量级对前端展示与「是否算命中」的阈值判断都有用，无敌人时不该丢。
  const fused: { chunkId: string; score: number }[] =
    channels.length === 1
      ? (channels[0]?.ranked ?? []).slice(0, topK)
      : fuseRrf(channels, topK)
  const meta: Map<string, ChunkMeta> = loadChunkMeta(
    deps.db,
    fused.map((f) => f.chunkId)
  )

  const hits: SearchHit[] = []
  for (const item of fused) {
    const info: ChunkMeta | undefined = meta.get(item.chunkId)
    if (info === undefined) {
      continue
    }
    hits.push({
      itemId: info.itemId,
      name: info.name,
      section: info.section,
      snippet: makeSnippet(info.text, tokens),
      score: Math.round(item.score * 10000) / 10000,
      channel: 'keyword',
    })
  }

  return {
    hits,
    tookMs: Date.now() - started,
    degraded: false,
    channels: ['keyword'],
  }
}
