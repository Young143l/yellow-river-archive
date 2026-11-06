import { common } from '@kit.AbilityKit'
import { relationalStore } from '@kit.ArkData'

import type { HeritageItem } from '../shared'
import { Tables } from '../model/Schema'
import { TextTokenizer } from '../utils/TextTokenizer'
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
  /** 命中来源：字段 / 正文 / 两者 / 筛选 */
  readonly channel: string
  /** 可解释的命中理由 */
  readonly reason: string
}

const MAX_HITS: number = 30

/** 正文片段的内存副本 */
interface ChunkRow {
  readonly itemId: string
  readonly section: string
  readonly text: string
  readonly tokens: string[]
}

/**
 * 端侧关键词检索。
 *
 * 两路并用：
 *   1. **分词匹配** —— 查询串经词典最大匹配切词后与片段 tokens 求交，权重高
 *   2. **原文子串兜底** —— 未登录词、错字、单字输入也能命中，权重低
 *
 * 片段在首次检索时一次性读进内存：百条级档案约千余个片段、不足 1MB，
 * 换取每次检索的零 IO 与更细的打分能力。
 */
export class SearchService {
  private static chunks: ChunkRow[] | undefined = undefined
  private static tokenizer: TextTokenizer | undefined = undefined
  /**
   * 词的文档频率（出现在多少个片段里）。
   *
   * 为什么要这个：原先打分是 tokenHits * 22，不管词多常见都同权。
   * 「黄河」几乎每条正文都有，全量时会把大部分条目以同分顶上来，
   * 排序等于随机；而「绿松石」只在一两处出现，才是真正区分性的信号。
   * 这就是 ADR-037 里没做完的那半句：兑底要过滤弱命中。
   */
  private static df: Map<string, number> = new Map<string, number>()
  private static docCount: number = 0

  /** 预热：加载片段与词表（幂等） */
  static async ready(context: common.Context): Promise<void> {
    await HeritageDao.ready(context)
    if (SearchService.chunks !== undefined && SearchService.tokenizer !== undefined) {
      return
    }

    const vocabBytes: Uint8Array = await context.resourceManager.getRawFileContent('data/vocab.json')
    SearchService.tokenizer = TextTokenizer.fromVocabBytes(vocabBytes)

    const store: relationalStore.RdbStore = await DataImportService.open(context)
    const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(Tables.CHUNKS)
    const rs: relationalStore.ResultSet = await store.query(predicates, [
      'item_id',
      'section',
      'text',
      'tokens',
    ])
    const itemCol: number = rs.getColumnIndex('item_id')
    const sectionCol: number = rs.getColumnIndex('section')
    const textCol: number = rs.getColumnIndex('text')
    const tokensCol: number = rs.getColumnIndex('tokens')

    const loaded: ChunkRow[] = []
    while (rs.goToNextRow()) {
      const rawTokens: string = rs.getString(tokensCol)
      loaded.push({
        itemId: rs.getString(itemCol),
        section: rs.getString(sectionCol),
        text: rs.getString(textCol),
        tokens: rawTokens.length > 0 ? rawTokens.split(' ') : [],
      })
    }
    rs.close()
    SearchService.chunks = loaded

    // 文档频率：每个片段的同词只计一次（df 是「多少篇里有」，不是「出现多少次」）
    const df: Map<string, number> = new Map<string, number>()
    for (const chunk of loaded) {
      const seen: Set<string> = new Set<string>(chunk.tokens)
      for (const t of seen) {
        df.set(t, (df.get(t) ?? 0) + 1)
      }
    }
    SearchService.df = df
    SearchService.docCount = loaded.length
  }

  /**
   * 稀有度权重 IDF。常见词接近 1，生僻词可到 6。
   * 未登录词当作最稀有处理（df=0）——专有名词、错字正是靠它命中。
   */
  private static idf(token: string): number {
    const d: number = SearchService.df.get(token) ?? 0
    return Math.log(1 + (SearchService.docCount + 1) / (d + 1))
  }

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

  /** 正文片段命中：分词匹配（高权重）+ 子串兜底（低权重） */
  private static scoreChunks(query: string, queryTokens: string[]): Map<string, ChunkHit> {
    const hits: Map<string, ChunkHit> = new Map<string, ChunkHit>()
    const chunks: ChunkRow[] = SearchService.chunks !== undefined ? SearchService.chunks : []

    for (const chunk of chunks) {
      let tokenHits: number = 0
      let idfSum: number = 0
      for (const qt of queryTokens) {
        if (qt.length >= 2 && chunk.tokens.includes(qt)) {
          tokenHits += 1
          idfSum += SearchService.idf(qt)
        }
      }

      const subAt: number = SearchService.indexOf(chunk.text, query)
      const matched: boolean = tokenHits > 0 || subAt >= 0
      if (!matched) {
        continue
      }

      // 按词的稀有度计分，而不是按命中个数同权相加
      const base: number = idfSum * 9 + (subAt >= 0 ? 18 : 0)
      const existing: ChunkHit | undefined = hits.get(chunk.itemId)
      if (existing === undefined || base > existing.weight) {
        hits.set(chunk.itemId, {
          itemId: chunk.itemId,
          section: chunk.section,
          snippet: SearchService.snippet(chunk.text, subAt >= 0 ? subAt : 0, query.length),
          weight: base,
          tokenHits,
        })
      }
    }
    return hits
  }

  /**
   * 执行检索。结果按分数降序。
   * 查询串与筛选条件在函数入口即锁定，避免异步过程中状态变化导致结果与展示不一致。
   */
  static async search(
    context: common.Context,
    query: string,
    filter?: HeritageFilter
  ): Promise<SearchHit[]> {
    const trimmed: string = query.trim()
    await SearchService.ready(context)

    const candidates: HeritageSummary[] = HeritageDao.list(filter)
    if (trimmed.length === 0) {
      const filtered: SearchHit[] = []
      for (const c of candidates) {
        filtered.push({
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
      return filtered.slice(0, MAX_HITS)
    }

    const tokenizer: TextTokenizer | undefined = SearchService.tokenizer
    const queryTokens: string[] = tokenizer !== undefined ? tokenizer.tokenize(trimmed) : [trimmed]
    const chunkHits: Map<string, ChunkHit> = SearchService.scoreChunks(trimmed, queryTokens)

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
        score += chunk.weight
        channel = channel === 'field' ? 'both' : 'text'
        if (snippet.length === 0) {
          snippet = chunk.snippet
        }
        if (reason.length === 0) {
          reason = chunk.tokenHits > 0 ? `正文含「${trimmed}」` : '正文命中'
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

    /*
     * 弱命中过滤。只在「确实有强命中」时生效：
     *   顶部是字段级命中（≥ 25）时，丢掉不足其 18% 的正文噪声；
     *   全是正文命中时不过滤 —— 那是用户唯一能得的结果，宁多勿缺。
     * 这样「黄河」这类全库常见词不会把整库条目同分顶上来，
     * 而「绿松石龙」这种只在正文出现的说法仍能搜到。
     */
    const top: number = scored.length > 0 ? scored[0].score : 0
    if (top >= 25) {
      const floor: number = top * 0.18
      const kept: SearchHit[] = scored.filter((h: SearchHit) => h.score >= floor)
      return kept.slice(0, MAX_HITS)
    }
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
  readonly weight: number
  readonly tokenHits: number
}
