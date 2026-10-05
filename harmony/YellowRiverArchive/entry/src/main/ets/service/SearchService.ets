import { common } from '@kit.AbilityKit'
import { relationalStore } from '@kit.ArkData'

import type { HeritageItem } from '../shared'
import { Tables } from '../model/Schema'
import { DataImportService } from './DataImportService'
import { HeritageDao, type HeritageFilter, type HeritageSummary } from './HeritageDao'

/** 检索命中 */
export interface SearchHit {
  readonly itemId: string
  readonly name: string
  readonly city: string
  readonly era: string
  readonly section: string
  readonly snippet: string
  readonly score: number
  /** 命中来源：字段命中 / 正文命中 / 两者 */
  readonly channel: string
  /** 可解释的命中理由 */
  readonly reason: string
}

const MAX_HITS: number = 30;

/**
 * 端侧关键词检索。
 *
 * D1 实现：条目字段匹配（名称 > 别名 > 关键词 > 概述）+ 正文片段子串匹配。
 * 分词结果（tokens）在 D2 阶段由流水线注入，D1 阶段 tokens 为空，
 * 因此这里以"原文子串"为主通道 —— 这正是设计文档里要求的兜底路径。
 */
export class SearchService {
  /** 判断查询串是否命中某个文本，返回命中位置（-1 表示未命中） */
  private static indexOf(haystack: string, needle: string): number {
    return haystack.toLowerCase().indexOf(needle.toLowerCase())
  }

  private static snippet(text: string, at: number, length: number): string {
    const start: number = Math.max(0, at - 30)
    const end: number = Math.min(text.length, at + length + 60)
    const prefix: string = start > 0 ? '…' : ''
    const suffix: string = end < text.length ? '…' : ''
    return prefix + text.slice(start, end) + suffix
  }

  /** 条目字段命中打分 */
  private static scoreItem(item: HeritageItem, query: string): ItemScore {
    let score: number = 0
    const reasons: string[] = []
    let snippet: string = ''

    if (SearchService.indexOf(item.name, query) >= 0) {
      score += 100
      reasons.push('名称命中')
    }
    for (const alias of item.aliases) {
      if (SearchService.indexOf(alias, query) >= 0) {
        score += 80
        reasons.push('别名命中')
        break
      }
    }
    for (const kw of item.keywords) {
      if (SearchService.indexOf(kw, query) >= 0) {
        score += 60
        reasons.push(`关键词：${kw}`)
        break
      }
    }
    const summaryAt: number = SearchService.indexOf(item.summary, query)
    if (summaryAt >= 0) {
      score += 40
      reasons.push('概述命中')
      snippet = SearchService.snippet(item.summary, summaryAt, query.length)
    }
    if (SearchService.indexOf(item.city as string, query) >= 0) {
      score += 25
      reasons.push(`城市：${item.city}`)
    }
    if (SearchService.indexOf(item.era as string, query) >= 0) {
      score += 25
      reasons.push(`时代：${item.era}`)
    }
    for (const t of item.types) {
      if (SearchService.indexOf(t as string, query) >= 0) {
        score += 25
        reasons.push(`类型：${t}`)
        break
      }
    }
    for (const artifact of item.artifacts) {
      if (SearchService.indexOf(artifact.name, query) >= 0) {
        score += 55
        reasons.push(`文物：${artifact.name}`)
        break
      }
    }

    return { score, reason: reasons.length > 0 ? reasons[0] : '', snippet }
  }

  /** 正文片段命中（走 RDB 的 LIKE，避免把全部正文读进内存） */
  private static async scoreChunks(
    context: common.Context,
    query: string
  ): Promise<Map<string, ChunkHit>> {
    const store: relationalStore.RdbStore = await DataImportService.open(context)
    const pattern: string = `%${query}%`
    const rs: relationalStore.ResultSet = await store.querySql(
      `SELECT item_id, section, text FROM ${Tables.CHUNKS} WHERE text LIKE ? LIMIT 60`,
      [pattern]
    )

    const hits: Map<string, ChunkHit> = new Map<string, ChunkHit>()
    const itemCol: number = rs.getColumnIndex('item_id')
    const sectionCol: number = rs.getColumnIndex('section')
    const textCol: number = rs.getColumnIndex('text')
    while (rs.goToNextRow()) {
      const itemId: string = rs.getString(itemCol)
      const text: string = rs.getString(textCol)
      const at: number = SearchService.indexOf(text, query)
      const hit: ChunkHit = {
        itemId,
        section: rs.getString(sectionCol),
        snippet: SearchService.snippet(text, at >= 0 ? at : 0, query.length),
      }
      if (!hits.has(itemId)) {
        hits.set(itemId, hit)
      }
    }
    rs.close()
    return hits
  }

  /**
   * 执行检索。
   * 结果按分数降序；同分时优先"字段命中"的条目。
   */
  static async search(
    context: common.Context,
    query: string,
    filter?: HeritageFilter
  ): Promise<SearchHit[]> {
    const trimmed: string = query.trim()
    await HeritageDao.ready(context)

    // 无关键词时退化为纯筛选
    const candidates: HeritageSummary[] = HeritageDao.list(filter)
    if (trimmed.length === 0) {
      const result: SearchHit[] = []
      for (const c of candidates) {
        result.push({
          itemId: c.id,
          name: c.name,
          city: c.city as string,
          era: c.era as string,
          section: 'intro',
          snippet: c.summary,
          score: 1,
          channel: 'filter',
          reason: '符合筛选条件',
        })
      }
      return result.slice(0, MAX_HITS)
    }

    const chunkHits: Map<string, ChunkHit> = await SearchService.scoreChunks(context, trimmed)
    const scored: SearchHit[] = []

    for (const summary of candidates) {
      const item: HeritageItem | undefined = HeritageDao.detail(summary.id)
      if (item === undefined) {
        continue
      }
      const fieldScore: ItemScore = SearchService.scoreItem(item, trimmed)
      const chunk: ChunkHit | undefined = chunkHits.get(item.id)

      let score: number = fieldScore.score
      let channel: string = fieldScore.score > 0 ? 'field' : ''
      let snippet: string = fieldScore.snippet
      let reason: string = fieldScore.reason

      if (chunk !== undefined) {
        score += 30
        channel = channel === 'field' ? 'both' : 'text'
        if (snippet.length === 0) {
          snippet = chunk.snippet
        }
        if (reason.length === 0) {
          reason = '正文命中'
        }
      }

      if (score > 0) {
        scored.push({
          itemId: item.id,
          name: item.name,
          city: item.city as string,
          era: item.era as string,
          section: chunk !== undefined ? chunk.section : 'intro',
          snippet: snippet.length > 0 ? snippet : item.summary,
          score,
          channel,
          reason: reason.length > 0 ? reason : '相关',
        })
      }
    }

    scored.sort((a: SearchHit, b: SearchHit) => b.score - a.score)
    return scored.slice(0, MAX_HITS)
  }
}

interface ItemScore {
  readonly score: number
  readonly reason: string
  readonly snippet: string
}

interface ChunkHit {
  readonly itemId: string
  readonly section: string
  readonly snippet: string
}
