/**
 * RAG 问答服务。
 *
 * 链路：查询理解 → 混合检索 → 图谱增强 → 流式生成 → 引用回传。
 *
 * 两条纪律：
 *
 * 1. **只依据检索到的片段作答，每条结论标 [n]**。这是 RAG 可信度的全部依据 ——
 *    没有引用的回答和直接问模型没有区别，用户无法核实。
 *
 * 2. **失败必须降级而非报错**。四级降级链（设计文档 6.2）：
 *    精排抖动→跳过重排；向量抖动→仅 BM25；LLM 不可用→**抽取式回答**（Top-3 片段摘要）；
 *    完全断网→端侧自行处理。抽取式降级是关键：它让「AI 挂了」变成「换了一种答法」，
 *    演示不至于中断。
 */

import type { LlmProvider } from '@yra/ai'
import type { Citation, GraphPath, GraphRelation, Section } from '@yra/shared'

import type { Db } from '../db/index'
import type { SearchDeps } from '../search/service'
import { search } from '../search/service'
import { withUsage } from '../search/usage'

/** 送去生成的片段数。太多会稀释注意力，太少证据不足 */
const CONTEXT_TOP_K: number = 6

/** 图谱增强最多带几条路径（展示用，多了会淹没正文） */
const MAX_GRAPH_PATHS: number = 6

/** 回答长度上限 */
const MAX_ANSWER_TOKENS: number = 1200

export interface QaDeps {
  readonly db: Db
  readonly searchDeps: SearchDeps
  readonly llm: LlmProvider
}

/** 流式产出的事件 */
export interface QaDeltaEvent {
  readonly kind: 'delta'
  readonly text: string
}

export interface QaDoneEvent {
  readonly kind: 'done'
  readonly answer: string
  readonly citations: Citation[]
  readonly graphPaths: GraphPath[]
  readonly degraded: boolean
  readonly note: string
}

export type QaEvent = QaDeltaEvent | QaDoneEvent

interface RetrievedChunk {
  readonly chunkId: string
  readonly itemId: string
  readonly itemName: string
  readonly section: Section
  readonly text: string
}

const SYSTEM_PROMPT: string = [
  '你是「黄河图志」的讲解助手，只依据用户提供的资料回答问题。',
  '',
  '硬约束（违反即作废）：',
  '1. 只使用资料中的信息，不得编造年代、数字、人名、地名。',
  '2. 每个结论后面用 [数字] 标注它依据的资料编号，例如「宫城位于遗址中部[2]」。',
  '3. 资料中没有的内容，直接回答「档案中暂无相关记载」，不要推测。',
  '4. 不要复述资料原文，要针对问题做归纳；不要罗列资料编号清单。',
  '',
  '文风：现代书面中文，客观陈述，控制在 300 字以内。',
  '不要用「根据资料」「综上所述」「本文将」这类填充语，直接给答案。',
].join('\n')

function sectionLabel(section: Section): string {
  if (section === 'intro') {
    return '图文介绍'
  }
  if (section === 'archaeology') {
    return '考古发现'
  }
  if (section === 'events') {
    return '历史事件'
  }
  if (section === 'poems') {
    return '相关诗词'
  }
  if (section === 'travel') {
    return '文旅信息'
  }
  return '知识图谱'
}

/** 拉取候选片段的正文（检索只回片段 id 与摘要，生成需要完整文本） */
function loadRetrievedChunks(db: Db, hitChunkIds: readonly string[]): RetrievedChunk[] {
  if (hitChunkIds.length === 0) {
    return []
  }
  const placeholders: string = hitChunkIds.map(() => '?').join(',')
  const rows = db
    .prepare(
      `SELECT c.id AS chunkId, c.item_id AS itemId, c.section AS section, c.text AS text, i.name AS itemName
         FROM chunks c JOIN items i ON i.id = c.item_id
        WHERE c.id IN (${placeholders})`
    )
    .all(...hitChunkIds) as unknown as RetrievedChunk[]

  // 保持检索给出的顺序 —— SQL 的 IN 不保证顺序，重排会破坏相关性
  const byId = new Map<string, RetrievedChunk>()
  for (const row of rows) {
    byId.set(row.chunkId, row)
  }
  const ordered: RetrievedChunk[] = []
  for (const id of hitChunkIds) {
    const chunk: RetrievedChunk | undefined = byId.get(id)
    if (chunk !== undefined) {
      ordered.push(chunk)
    }
  }
  return ordered
}

/** 组装给模型的资料块 */
function buildContext(chunks: readonly RetrievedChunk[]): string {
  const lines: string[] = []
  chunks.forEach((chunk, index) => {
    lines.push(`【资料 ${index + 1}】${chunk.itemName} · ${sectionLabel(chunk.section)}`)
    lines.push(chunk.text)
    lines.push('')
  })
  return lines.join('\n')
}

/**
 * 把回答里真正引用到的资料编号抽出来。
 *
 * 为什么要抽：送进模型的资料有 6 条，但回答通常只用到 2-3 条。
 * 把没用到的也回传，引用区就是噪声 —— 用户会以为那些都支撑了结论，
 * 点进去却发现无关。**引用区的价值在于「每条结论都可核查」，不在于条目多。**
 *
 * 缺省行为：**解析不到编号就不返回引用**。「档案中暂无相关记载」这类回答
 * 本就没有引用，此时列出资料反而是误导。
 */
export function parseCitedIndexes(answer: string): number[] {
  const found: number[] = []
  const pattern = /\[(\d+)\]/g
  let match: RegExpExecArray | null = pattern.exec(answer)
  while (match !== null) {
    const n: number = Number.parseInt(match[1] ?? '0', 10)
    if (n > 0 && !found.includes(n)) {
      found.push(n)
    }
    match = pattern.exec(answer)
  }
  found.sort((a, b) => a - b)
  return found
}

/** 按被引用的编号筛出引用，并**重新编号**（原文是 [6][2]，展示应连续为 [1][2]） */
function toCitations(chunks: readonly RetrievedChunk[], citedIndexes: readonly number[]): Citation[] {
  const citations: Citation[] = []
  citedIndexes.forEach((originalIndex, position) => {
    const chunk: RetrievedChunk | undefined = chunks[originalIndex - 1]
    if (chunk === undefined) {
      return
    }
    citations.push({
      chunkId: chunk.chunkId,
      itemId: chunk.itemId,
      title: `${position + 1}. ${chunk.itemName} · ${sectionLabel(chunk.section)}`,
      snippet: chunk.text.slice(0, 120),
      section: chunk.section,
    })
  })
  return citations
}

/** 只保留被引用条目相关的图谱路径 —— 未被引用的条目与结论无关 */
function filterGraphPaths(
  paths: readonly GraphPath[],
  chunks: readonly RetrievedChunk[],
  citedIndexes: readonly number[]
): GraphPath[] {
  const usedItemIds: string[] = []
  for (const index of citedIndexes) {
    const chunk: RetrievedChunk | undefined = chunks[index - 1]
    if (chunk !== undefined && !usedItemIds.includes(chunk.itemId)) {
      usedItemIds.push(chunk.itemId)
    }
  }
  return paths.filter((p) => usedItemIds.includes(p.from) || usedItemIds.includes(p.to))
}

/**
 * 图谱增强：把命中条目在知识图谱里的直接关系取出来，作为「证据链」展示。
 *
 * 它的价值不是提升生成质量，而是**让回答可核查** —— 用户能顺着路径自己验证。
 * 因此这里只取一跳、按权重降序、限量，不做多跳展开（多跳路径的可读性会迅速下降）。
 */
function collectGraphPaths(db: Db, itemIds: readonly string[]): GraphPath[] {
  if (itemIds.length === 0) {
    return []
  }
  const placeholders: string = itemIds.map(() => '?').join(',')
  const rows = db
    .prepare(
      `SELECT e.src AS src, e.dst AS dst, e.rel AS rel, e.weight AS weight,
              ns.name AS srcName, nd.name AS dstName
         FROM kg_edges e
         LEFT JOIN kg_nodes ns ON ns.id = e.src
         LEFT JOIN kg_nodes nd ON nd.id = e.dst
        WHERE e.src IN (${placeholders})
        ORDER BY e.weight DESC
        LIMIT ?`
    )
    .all(...itemIds, MAX_GRAPH_PATHS) as unknown as {
    src: string
    dst: string
    rel: string
    weight: number
    srcName: string | null
    dstName: string | null
  }[]

  const paths: GraphPath[] = []
  for (const row of rows) {
    paths.push({
      from: row.src,
      fromName: row.srcName ?? row.src,
      rel: row.rel as GraphRelation,
      to: row.dst,
      toName: row.dstName ?? row.dst,
    })
  }
  return paths
}

/**
 * 抽取式回答（LLM 不可用时的兜底）。
 *
 * 不是「装作回答了」—— 它如实说明 AI 不可用，并把最相关的片段摘要摆出来。
 * 用户仍能拿到有用信息，且清楚知道这不是生成的答案。
 */
function extractiveAnswer(chunks: readonly RetrievedChunk[]): string {
  const parts: string[] = ['AI 生成服务当前不可用，以下是档案中与问题最相关的原文摘要：', '']
  chunks.slice(0, 3).forEach((chunk, index) => {
    parts.push(`${index + 1}. ${chunk.itemName} · ${sectionLabel(chunk.section)}`)
    parts.push(`   ${chunk.text.slice(0, 100)}${chunk.text.length > 100 ? '…' : ''}`)
    parts.push('')
  })
  parts.push('（恢复联网后可获得完整的归纳回答）')
  return parts.join('\n')
}

/**
 * 回答一个问题，流式产出事件。
 *
 * 注意：本函数**不抛异常**。检索失败、生成失败都走降级分支，
 * 因为问答是演示的主路径，中断的代价远高于答得差一点。
 */
export async function* answerQuestion(
  deps: QaDeps,
  question: string
): AsyncGenerator<QaEvent, void, undefined> {
  // ---- 1. 混合检索 ----
  let chunkIds: string[] = []
  try {
    const searchResult = await search(deps.searchDeps, { query: question, topK: CONTEXT_TOP_K })
    chunkIds = searchResult.hits.map((hit) => hit.chunkId)
  } catch (err) {
    chunkIds = []
  }

  const chunks: RetrievedChunk[] = loadRetrievedChunks(deps.db, chunkIds)

  if (chunks.length === 0) {
    yield {
      kind: 'done',
      answer: '档案中暂无相关记载。可以换个说法，或先浏览时间轴上的条目。',
      citations: [],
      graphPaths: [],
      degraded: false,
      note: '检索无命中',
    }
    return
  }

  const itemIds: string[] = []
  for (const chunk of chunks) {
    if (!itemIds.includes(chunk.itemId)) {
      itemIds.push(chunk.itemId)
    }
  }
  const allGraphPaths: GraphPath[] = collectGraphPaths(deps.db, itemIds)

  // ---- 2. 生成 ----
  const messages = [
    { role: 'system' as const, content: SYSTEM_PROMPT },
    {
      role: 'user' as const,
      content: `资料：\n${buildContext(chunks)}\n\n问题：${question}`,
    },
  ]

  let answer: string = ''
  let streamOk: boolean = false
  let streamError: string = ''
  console.log(`[qa] 检索到 ${chunks.length} 个片段，准备生成（问题：${question.slice(0, 20)}）`)
  try {
    const stream: AsyncIterable<string> = await withUsage(deps.db, 'qa_generate', deps.llm, () =>
      deps.llm.stream(messages, { temperature: 0.2, maxTokens: MAX_ANSWER_TOKENS, timeoutMs: 60_000 })
    )
    streamOk = true
    for await (const delta of stream) {
      answer += delta
      yield { kind: 'delta', text: delta }
    }
    console.log(`[qa] 流式结束，累计 ${answer.length} 字`)
  } catch (err) {
    streamOk = false
    streamError = err instanceof Error ? err.message : String(err)
    console.error(`[qa] 生成失败：${streamError.slice(0, 200)}`)
  }

  if (!streamOk || answer.trim().length === 0) {
    console.error(`[qa] 降级为抽取式（streamOk=${streamOk} answerLen=${answer.length} err=${streamError.slice(0, 120)}）`)
    // ---- 降级：抽取式回答 ----
    // 抽取式回答展示的是 Top-3 原文摘要，因此这三条**全部**算作引用
    const fallback: string = extractiveAnswer(chunks)
    const fallbackIndexes: number[] = [1, 2, 3].filter((n) => n <= chunks.length)
    yield { kind: 'delta', text: fallback }
    yield {
      kind: 'done',
      answer: fallback,
      citations: toCitations(chunks, fallbackIndexes),
      graphPaths: filterGraphPaths(allGraphPaths, chunks, fallbackIndexes),
      degraded: true,
      note: '生成服务不可用，已降级为抽取式回答',
    }
    return
  }

  const citedIndexes: number[] = parseCitedIndexes(answer)
  yield {
    kind: 'done',
    answer,
    citations: toCitations(chunks, citedIndexes),
    graphPaths: filterGraphPaths(allGraphPaths, chunks, citedIndexes),
    degraded: false,
    note: citedIndexes.length === 0 ? '本轮回答未引用档案资料' : '',
  }
}
