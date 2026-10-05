/**
 * 数据质检。
 *
 * 分两层：
 *   - **硬错误（error）**：会让作品出问题或违规的事项，必须修 —— 抄袭重合、
 *     图片无授权信息、字段结构不合法、赛题点名的类型缺失等
 *   - **软提醒（warning）**：不违规但质量欠佳 —— 字数偏离推荐区间、时代轴出现空洞等
 *
 * 为什么 n-gram 查重放在这里而不是靠人工读：赛题明确「严禁抄袭、剽窃」，
 * 一旦被判抄袭直接取消资格。人工目检靠不住，必须机器把关。
 *
 * 命令：pnpm data:lint
 */

import { existsSync } from 'node:fs'
import { readFile, readdir } from 'node:fs/promises'
import { join } from 'node:path'

import type { HeritageItem, VocabEntry, Chunk } from '@yra/shared'

/** n-gram 长度：连续重合超过这个字数即判为抄袭风险 */
const NGRAM_SIZE: number = 15

/** 各字段的推荐字数区间（与 Zod 的硬边界不同，这里更严，仅提醒） */
const RECOMMENDED: Record<string, { min: number; max: number }> = {
  summary: { min: 15, max: 100 },
  intro: { min: 300, max: 800 },
  archaeology: { min: 200, max: 600 },
}

export interface LintIssue {
  readonly level: 'error' | 'warning'
  /** 归属对象：条目 id 或 'distribution' / 'index' */
  readonly target: string
  readonly field: string
  readonly message: string
}

export interface LintReport {
  readonly issues: LintIssue[]
  readonly errorCount: number
  readonly warningCount: number
  readonly stats: {
    readonly items: number
    readonly itemsWithSource: number
    readonly ngramHits: number
    readonly placeholderItems: number
  }
}

/** 归一化：去掉空白、标点与符号，只留实义字符 */
function normalize(text: string): string {
  return text.replace(/[\s\p{P}\p{S}]/gu, '')
}

/** 收集一个条目里所有可读文本，用于查重 */
export function collectText(item: HeritageItem): string {
  const parts: string[] = [item.name, item.summary, item.intro, item.archaeology]
  for (const e of item.events) {
    parts.push(e.title, e.desc)
  }
  for (const p of item.poems) {
    parts.push(p.title, p.content, p.note ?? '')
  }
  if (item.travel !== undefined) {
    parts.push(item.travel.hours ?? '', item.travel.ticket ?? '', item.travel.best ?? '')
    parts.push(...item.travel.tips)
  }
  for (const a of item.artifacts) {
    parts.push(a.name, a.desc)
  }
  for (const f of item.figures) {
    parts.push(f.name, f.role, f.desc)
  }
  return parts.join('\n')
}

interface Run {
  readonly text: string
  readonly length: number
}

/**
 * 找出作品文本与来源文本的连续重合段。
 *
 * 做法：把来源切成全部 N 字滑窗存入集合，再扫作品文本的滑窗；
 * 相邻命中合并成连续段，便于人工定位与改写。
 */
export function findOverlapRuns(
  itemText: string,
  sourceText: string,
  n: number = NGRAM_SIZE
): Run[] {
  const source: string = normalize(sourceText)
  const target: string = normalize(itemText)
  if (source.length < n || target.length < n) {
    return []
  }

  const index: Map<string, number[]> = new Map<string, number[]>()
  for (let i = 0; i + n <= source.length; i++) {
    const gram: string = source.slice(i, i + n)
    const positions: number[] | undefined = index.get(gram)
    if (positions === undefined) {
      index.set(gram, [i])
    } else {
      positions.push(i)
    }
  }

  const runs: Run[] = []
  let runStart: number = -1
  let runLength: number = 0

  for (let i = 0; i + n <= target.length; i++) {
    const gram: string = target.slice(i, i + n)
    const hit: boolean = index.has(gram)
    if (hit) {
      if (runStart < 0) {
        runStart = i
        runLength = n
      } else {
        runLength += 1
      }
    } else if (runStart >= 0) {
      runs.push({ text: target.slice(runStart, runStart + runLength), length: runLength })
      runStart = -1
      runLength = 0
    }
  }
  if (runStart >= 0) {
    runs.push({ text: target.slice(runStart, runStart + runLength), length: runLength })
  }
  return runs
}

/** 逐条质检 */
export function lintItem(item: HeritageItem, sourceText?: string): LintIssue[] {
  const issues: LintIssue[] = []
  const add = (level: 'error' | 'warning', field: string, message: string): void => {
    issues.push({ level, target: item.id, field, message })
  }

  // 推荐字数（硬边界由 Zod 保证，这里只提醒偏离）
  for (const [field, range] of Object.entries(RECOMMENDED)) {
    const value: string = field === 'summary' ? item.summary : field === 'intro' ? item.intro : item.archaeology
    const length: number = value.replace(/\s/g, '').length
    if (length < range.min) {
      add('warning', field, `偏短：${length} 字（建议 ${range.min}-${range.max}）`)
    } else if (length > range.max) {
      add('warning', field, `偏长：${length} 字（建议 ${range.min}-${range.max}）`)
    }
  }

  // 图片：授权信息与占位图
  item.images.forEach((img, i) => {
    const field: string = `images[${i}]`
    if (img.credit.trim().length === 0 || img.license.trim().length === 0) {
      add('error', field, 'credit 或 license 为空（版权留痕缺失）')
    }
    const looksPlaceholder: boolean =
      img.caption.includes('占位') || img.credit.includes('占位') || img.license.includes('占位')
    if (looksPlaceholder) {
      add('warning', field, `占位图：${img.caption.slice(0, 30)}（P0 批次提交前必须替换）`)
    }
    if (!img.url.endsWith('.webp')) {
      add('warning', field, `图片不是 WebP 格式：${img.url}`)
    }
  })

  // 来源
  for (const [i, s] of item.sources.entries()) {
    if (!/^https?:\/\//.test(s.url)) {
      add('warning', `sources[${i}]`, `URL 格式可疑：${s.url}`)
    }
    if (!/^\d{4}-\d{2}-\d{2}$/.test(s.accessedAt)) {
      add('error', `sources[${i}]`, `访问日期格式应为 yyyy-MM-dd，实际 ${s.accessedAt}`)
    }
  }

  // 时代与年代的合理性
  if (item.eraRange !== undefined) {
    const [start, end] = item.eraRange
    if (start > end) {
      add('error', 'eraRange', `起始年 ${start} 大于结束年 ${end}`)
    }
  }

  // 诗词：无直接关联时必须写明
  item.poems.forEach((p, i) => {
    if (p.note === undefined || p.note.trim().length === 0) {
      add('warning', `poems[${i}]`, '未填写 note；若该诗并非本遗址直接关联，必须在此说明')
    }
  })

  // 关键词
  if (item.keywords.length < 3) {
    add('error', 'keywords', `关键词不足 3 个（当前 ${item.keywords.length}）`)
  }

  // n-gram 查重
  if (sourceText !== undefined) {
    const runs: Run[] = findOverlapRuns(collectText(item), sourceText)
    for (const run of runs) {
      add(
        'error',
        'n-gram',
        `与来源连续重合 ${run.length} 字（红线 ${NGRAM_SIZE} 字）：…${run.text.slice(0, 40)}…`
      )
    }
  }

  return issues
}

/** 质检阶段：开发期把覆盖度不足降为提醒，交付期必须达标 */
export type LintPhase = 'dev' | 'final'

/** 分布与覆盖度质检 */
export function lintDistribution(
  items: readonly HeritageItem[],
  allocation: Record<string, number>,
  phase: LintPhase = 'dev'
): LintIssue[] {
  const issues: LintIssue[] = []
  // 开发期数据尚未补齐，覆盖度不足属预期 → 降为提醒；交付期必须达标
  const coverageLevel: 'error' | 'warning' = phase === 'final' ? 'error' : 'warning'
  const push = (level: 'error' | 'warning', field: string, message: string): void => {
    issues.push({ level, target: 'distribution', field, message })
  }

  const tally = (pick: (i: HeritageItem) => string[]): Map<string, number> => {
    const map: Map<string, number> = new Map<string, number>()
    for (const item of items) {
      for (const key of pick(item)) {
        map.set(key, (map.get(key) ?? 0) + 1)
      }
    }
    return map
  }

  const byCity: Map<string, number> = tally((i) => [i.city as string])
  const byEra: Map<string, number> = tally((i) => [i.era as string])
  const byType: Map<string, number> = tally((i) => i.types.map((t) => t as string))

  // 城市：配额与最小数量
  for (const [city, quota] of Object.entries(allocation)) {
    const count: number = byCity.get(city) ?? 0
    if (count !== quota) {
      push('warning', 'city', `${city} 收录 ${count} 条，配额为 ${quota}`)
    }
    if (count < 8) {
      push(coverageLevel, 'city', `${city} 仅 ${count} 条，地图视图会出现空白（要求 ≥8）`)
    }
  }

  // 时代：六个主时代每段至少 8 条
  for (const era of ['仰韶', '龙山', '夏商', '周', '汉唐', '宋']) {
    const count: number = byEra.get(era) ?? 0
    if (count < 8) {
      push(coverageLevel, 'era', `${era} 仅 ${count} 条，时间轴会出现空洞（要求 ≥8）`)
    }
  }

  // 赛题点名的四类
  for (const type of ['都城遗址', '墓葬群', '窑址', '古建筑']) {
    const count: number = byType.get(type) ?? 0
    if (count < 6) {
      push(coverageLevel, 'type', `${type} 仅 ${count} 条（赛题点名类型，要求 ≥6）`)
    }
  }

  // 宋以后占比过高会把叙述带离赛题时代轴
  const afterSong: number = byEra.get('宋以后') ?? 0
  if (items.length >= 20 && afterSong / items.length > 0.2) {
    push(
      'warning',
      'era',
      `「宋以后」占 ${afterSong}/${items.length}（超过 20%），建议复核能否按文化主体归入更早时代`
    )
  }

  return issues
}

/** 清单与正文的一致性 */
export async function lintIndexConsistency(
  dataDir: string,
  contentDir: string,
  indexEntries: readonly { readonly id: string; readonly content?: string; readonly priority: string }[]
): Promise<LintIssue[]> {
  const issues: LintIssue[] = []
  const push = (level: 'error' | 'warning', target: string, message: string): void => {
    issues.push({ level, target, field: 'index', message })
  }

  const files: string[] = await readdir(contentDir).catch(() => [])
  const existing: Set<string> = new Set<string>(files.filter((f) => f.endsWith('.yaml')))

  for (const entry of indexEntries) {
    if (entry.content !== undefined) {
      const name: string = entry.content.replace(/^sites\//, '')
      if (!existing.has(name)) {
        push('error', entry.id, `清单标记 content=${entry.content}，但文件不存在`)
      }
    }
  }

  // 有正文但清单没登记
  const ids: Set<string> = new Set<string>(indexEntries.map((e) => e.id))
  for (const file of existing) {
    const id: string = file.replace(/\.yaml$/, '')
    if (!ids.has(id)) {
      push('warning', id, `存在正文文件 ${file}，但清单里没有这条`)
    }
  }

  void dataDir
  return issues
}

export interface LintInput {
  readonly items: readonly HeritageItem[]
  readonly allocation: Record<string, number>
  readonly sourcesDir: string
  readonly contentDir: string
  readonly indexEntries: readonly { readonly id: string; readonly content?: string; readonly priority: string }[]
  readonly phase?: LintPhase
}

/** 汇总质检 */
export async function lintAll(input: LintInput): Promise<LintReport> {
  const issues: LintIssue[] = []
  let itemsWithSource: number = 0
  let ngramHits: number = 0
  let placeholderItems: number = 0

  for (const item of input.items) {
    const sourcePath: string = join(input.sourcesDir, `${item.id}.md`)
    let sourceText: string | undefined = undefined
    if (existsSync(sourcePath)) {
      sourceText = await readFile(sourcePath, 'utf8')
      itemsWithSource += 1
    }
    const itemIssues: LintIssue[] = lintItem(item, sourceText)
    for (const issue of itemIssues) {
      if (issue.field === 'n-gram') {
        ngramHits += 1
      }
      if (issue.field.startsWith('images[') && issue.message.startsWith('占位图')) {
        placeholderItems += 1
      }
    }
    issues.push(...itemIssues)
  }

  issues.push(...lintDistribution(input.items, input.allocation, input.phase ?? 'dev'))
  issues.push(...(await lintIndexConsistency('.', input.contentDir, input.indexEntries)))

  const errorCount: number = issues.filter((i) => i.level === 'error').length
  const warningCount: number = issues.filter((i) => i.level === 'warning').length

  return {
    issues,
    errorCount,
    warningCount,
    stats: {
      items: input.items.length,
      itemsWithSource,
      ngramHits,
      placeholderItems,
    },
  }
}

/** 词表体检：过大或含异常词都会影响端侧体积与检索质量 */
export function lintVocab(entries: readonly VocabEntry[]): LintIssue[] {
  const issues: LintIssue[] = []
  if (entries.length > 15000) {
    issues.push({
      level: 'warning',
      target: 'vocab',
      field: 'size',
      message: `词表 ${entries.length} 词，体积可能超出预算（建议 ≤15000）`,
    })
  }
  const singleChar: VocabEntry[] = entries.filter((e) => e.word.length === 1)
  if (singleChar.length > entries.length * 0.5) {
    issues.push({
      level: 'warning',
      target: 'vocab',
      field: 'quality',
      message: `单字词占 ${singleChar.length}/${entries.length}，比例过高会稀释检索权重`,
    })
  }
  return issues
}

/** 分块体检：过短或过长的片段都会拉低检索质量 */
export function lintChunks(chunks: readonly Chunk[]): LintIssue[] {
  const issues: LintIssue[] = []
  const tooShort: Chunk[] = chunks.filter((c) => c.text.length < 20)
  const tooLong: Chunk[] = chunks.filter((c) => c.text.length > 600)
  const noTokens: Chunk[] = chunks.filter((c) => c.tokens.length === 0)

  if (tooShort.length > 0) {
    issues.push({
      level: 'warning',
      target: 'chunks',
      field: 'length',
      message: `${tooShort.length} 个片段短于 20 字，语义信息不足`,
    })
  }
  if (tooLong.length > 0) {
    issues.push({
      level: 'warning',
      target: 'chunks',
      field: 'length',
      message: `${tooLong.length} 个片段超过 600 字，可能挤压上下文预算`,
    })
  }
  if (noTokens.length > 0) {
    issues.push({
      level: 'error',
      target: 'chunks',
      field: 'tokens',
      message: `${noTokens.length} 个片段没有分词结果，端侧检索会失效`,
    })
  }
  return issues
}
