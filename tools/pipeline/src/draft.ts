/**
 * AI 起草流水线。
 *
 * 定位：这是**草稿生成器，不是内容生成器**。
 * 产物进 packages/data/drafts/，**禁止直接搬到 sites/**——必须经人工改写与交叉校对。
 *
 * 三条硬约束写在提示词里，缺一不可：
 *   1. 只能用来源摘录里的信息，不得编造年代、数字、人名、地名
 *   2. 不确定的信息标 [待核实]，让改写的人知道该去查什么
 *   3. 每条事实句标来源编号 [1][2]，便于核对
 *
 * 命令：pnpm data:draft
 */

import { existsSync } from 'node:fs'
import { mkdir, readFile, writeFile } from 'node:fs/promises'
import { join } from 'node:path'

import { DeepSeekLlm, readEnv, type ChatMessage, type LlmProvider } from '@yra/ai'
import { stringify as stringifyYaml } from 'yaml'

import type { City, Era, HeritageType, Level } from '@yra/shared'

/** 清单条目（只取起草需要的字段） */
export interface DraftTarget {
  readonly id: string
  readonly name: string
  readonly city: string
  readonly era: string
  readonly eraRange?: number[]
  readonly types: string[]
  readonly level: string
  readonly batch?: number
  readonly notes?: string
}

interface DraftContent {
  readonly summary: string
  readonly intro: string
  readonly archaeology: string
  readonly events: { year: string; title: string; desc: string }[]
  readonly poems: { title: string; author: string; dynasty: string; content: string; note?: string }[]
  readonly travel?: { hours?: string; ticket?: string; best?: string; tips: string[] }
  readonly artifacts: { name: string; desc: string; museum?: string }[]
  readonly figures: { name: string; role: string; desc: string }[]
  readonly keywords: string[]
  readonly imageHints?: string[]
}

export interface DraftReport {
  readonly id: string
  readonly ok: boolean
  readonly outPath: string
  readonly elapsedMs: number
  readonly message: string
}

const SYSTEM_PROMPT: string = [
  '你是考古文博领域的内容编辑，为「黄河图志」项目撰写文化遗产档案。',
  '你的输出会作为**草稿**交给人工改写，因此宁可标注不确定，也不要写得像是确定的事实。',
  '',
  '硬约束（违反即作废）：',
  '1. 只能使用用户提供的「来源摘录」中的信息。不得编造年代、数字、人名、地名、器物名。',
  '2. 来源中没有、但你有理由推断的内容，必须写成「[待核实] ……」。',
  '3. 每条事实性表述末尾用 [1][2] 标注它出自第几个来源。',
  '4. 只输出 JSON，不要输出任何解释、前言或 Markdown 代码块标记。',
  '',
  '文风要求：',
  '- 现代书面中文，客观陈述',
  '- 不用「本文」「综上所述」「值得一提的是」这类论文腔或填充语',
  '- 不用「欢迎参观」「值得一游」这类旅游软文腔',
  '- 学术争议用「学界多认为」「一般认为」，传说用「相传」',
  '',
  '最重要的一条心态：**来源信息不足时，宁可写短、宁可留空，也不要为凑字数而扩写**。',
  '你写的是草稿，少写不会有事；编造会直接毁掉整条档案的可信度。',
].join('\n')

function buildUserPrompt(target: DraftTarget, sourceText: string): string {
  const range: string =
    target.eraRange !== undefined
      ? `约公元前${Math.abs(target.eraRange[0] ?? 0)}—前${Math.abs(target.eraRange[1] ?? 0)}年`
      : '（未定）'

  const schema: string = [
    '{',
    '  "summary": "一句话概述，10-120 字",',
    '  "intro": "图文介绍，300-800 字，三段：在哪·有什么·意味着什么",',
    '  "archaeology": "考古发现，200-600 字，必须含发现时间、发现者、关键遗物、学术意义",',
    '  "events": [{"year": "年份", "title": "8 字以内", "desc": "一句话说清谁做了什么、结果如何"}],',
    '  "poems": [{"title": "", "author": "", "dynasty": "", "content": "", "note": "若非本遗址直接关联，必须在此说明"}],',
    '  "travel": {"hours": "", "ticket": "", "best": "", "tips": ["..."]},',
    '  "artifacts": [{"name": "可移动文物名（青铜器/玉器/陶器/瓷器等）", "desc": "一句话讲清是什么、为什么重要", "museum": "仅当来源明确说明馆藏地时才填"}],',
    '  "figures": [{"name": "", "role": "", "desc": ""}],',
    '  "keywords": ["至少 3 个，含专名与别名"],',
    '  "imageHints": ["建议配什么图，2-4 条"]',
    '}',
  ].join('\n')

  return [
    `## 条目元信息（已核定，直接引用，不要改动）`,
    `- 名称：${target.name}`,
    `- 城市：${target.city}`,
    `- 时代：${target.era}（${range}）`,
    `- 类型：${target.types.join('、')}`,
    `- 保护级别：${target.level}${target.batch !== undefined ? `（第 ${target.batch} 批）` : ''}`,
    target.notes !== undefined ? `- 备注：${target.notes}` : '',
    '',
    '## 来源摘录',
    sourceText,
    '',
    '## 输出要求',
    '严格按下面的 JSON 结构输出，不要增删字段：',
    schema,
    '',
    '补充说明：',
    '- poems 若来源中没有相关诗词，输出空数组 []，不要硬凑',
    '- travel 若来源中没有文旅信息，省略该字段',
    '- events 挑 2-5 条最重要的（发现、定名、列入国保、重要发掘或保护节点）',
    '- **artifacts 指可移动文物**（青铜器、玉器、陶器、瓷器、碑刻等）。',
    '  城墙、宫殿基址、窑炉这类**不可移动遗迹不能填进 artifacts**，它们属于 intro 或 archaeology；',
    '  来源中没有可移动文物就输出空数组 []',
    '- museum 仅当来源明确写了馆藏单位时才填，不要根据遗址名推测',
    '- 每条事实句末尾的 [n] 编号对应「来源摘录」里第 n 个来源',
  ]
    .filter((line) => line.length > 0)
    .join('\n')
}

/** 从模型输出里抠出 JSON（容错：模型偶尔会包一层代码块） */
export function extractJson(raw: string): string {
  const trimmed: string = raw.trim()
  const fenceMatch: RegExpMatchArray | null = trimmed.match(/```(?:json)?\s*([\s\S]*?)```/)
  const body: string = fenceMatch !== null && fenceMatch[1] !== undefined ? fenceMatch[1].trim() : trimmed
  const start: number = body.indexOf('{')
  const end: number = body.lastIndexOf('}')
  if (start < 0 || end <= start) {
    throw new Error(`模型输出中没有找到 JSON 对象：${trimmed.slice(0, 160)}`)
  }
  return body.slice(start, end + 1)
}

function asString(value: unknown, fallback: string = ''): string {
  return typeof value === 'string' ? value : fallback
}

function asStringArray(value: unknown): string[] {
  if (!Array.isArray(value)) {
    return []
  }
  return value.filter((v): v is string => typeof v === 'string')
}

/** 把模型输出规整成草稿结构，缺字段时给安全默认值 */
export function normalizeDraft(parsed: Record<string, unknown>): DraftContent {
  const events: { year: string; title: string; desc: string }[] = []
  if (Array.isArray(parsed.events)) {
    for (const raw of parsed.events) {
      if (typeof raw !== 'object' || raw === null) {
        continue
      }
      const e = raw as Record<string, unknown>
      events.push({
        year: asString(e.year),
        title: asString(e.title),
        desc: asString(e.desc),
      })
    }
  }

  const poems: { title: string; author: string; dynasty: string; content: string; note?: string }[] = []
  if (Array.isArray(parsed.poems)) {
    for (const raw of parsed.poems) {
      if (typeof raw !== 'object' || raw === null) {
        continue
      }
      const p = raw as Record<string, unknown>
      const note: string = asString(p.note)
      poems.push({
        title: asString(p.title),
        author: asString(p.author),
        dynasty: asString(p.dynasty),
        content: asString(p.content),
        ...(note.length > 0 ? { note } : {}),
      })
    }
  }

  const artifacts: { name: string; desc: string; museum?: string }[] = []
  if (Array.isArray(parsed.artifacts)) {
    for (const raw of parsed.artifacts) {
      if (typeof raw !== 'object' || raw === null) {
        continue
      }
      const a = raw as Record<string, unknown>
      const museum: string = asString(a.museum)
      artifacts.push({
        name: asString(a.name),
        desc: asString(a.desc),
        ...(museum.length > 0 ? { museum } : {}),
      })
    }
  }

  const figures: { name: string; role: string; desc: string }[] = []
  if (Array.isArray(parsed.figures)) {
    for (const raw of parsed.figures) {
      if (typeof raw !== 'object' || raw === null) {
        continue
      }
      const f = raw as Record<string, unknown>
      figures.push({
        name: asString(f.name),
        role: asString(f.role),
        desc: asString(f.desc),
      })
    }
  }

  let travel: { hours?: string; ticket?: string; best?: string; tips: string[] } | undefined = undefined
  if (typeof parsed.travel === 'object' && parsed.travel !== null) {
    const t = parsed.travel as Record<string, unknown>
    const hours: string = asString(t.hours)
    const ticket: string = asString(t.ticket)
    const best: string = asString(t.best)
    travel = {
      ...(hours.length > 0 ? { hours } : {}),
      ...(ticket.length > 0 ? { ticket } : {}),
      ...(best.length > 0 ? { best } : {}),
      tips: asStringArray(t.tips),
    }
  }

  return {
    summary: asString(parsed.summary),
    intro: asString(parsed.intro),
    archaeology: asString(parsed.archaeology),
    events,
    poems,
    ...(travel !== undefined ? { travel } : {}),
    artifacts,
    figures,
    keywords: asStringArray(parsed.keywords),
    imageHints: asStringArray(parsed.imageHints),
  }
}

/** 起草单条 */
export async function draftOne(
  provider: LlmProvider,
  target: DraftTarget,
  sourceText: string,
  outDir: string
): Promise<DraftReport> {
  const started: number = Date.now()
  await mkdir(outDir, { recursive: true })

  const messages: ChatMessage[] = [
    { role: 'system', content: SYSTEM_PROMPT },
    { role: 'user', content: buildUserPrompt(target, sourceText) },
  ]

  try {
    const raw: string = await provider.complete(messages, {
      temperature: 0.3,
      maxTokens: 4096,
      timeoutMs: 180_000,
      jsonMode: true,
    })
    const parsed = JSON.parse(extractJson(raw)) as Record<string, unknown>
    const content: DraftContent = normalizeDraft(parsed)

    const draft = {
      _meta: {
        status: '草稿',
        generatedAt: new Date().toISOString(),
        itemId: target.id,
        warning: '本文件由 AI 起草，禁止直接移入 sites/，必须经人工改写与交叉校对',
      },
      id: target.id,
      name: target.name,
      aliases: [],
      city: target.city as City,
      era: target.era as Era,
      ...(target.eraRange !== undefined
        ? { eraRange: [target.eraRange[0] ?? 0, target.eraRange[1] ?? 0] }
        : {}),
      types: target.types as HeritageType[],
      level: target.level as Level,
      geo: { lat: 0, lng: 0 },
      summary: content.summary,
      intro: content.intro,
      archaeology: content.archaeology,
      events: content.events,
      poems: content.poems,
      ...(content.travel !== undefined ? { travel: content.travel } : {}),
      artifacts: content.artifacts.map((a, i) => ({ ...a, id: `${target.id}#${i + 1}` })),
      figures: content.figures,
      images: [],
      keywords: content.keywords,
      sources: [],
      _imageHints: content.imageHints ?? [],
    }

    const outPath: string = join(outDir, `${target.id}.yaml`)
    await writeFile(outPath, stringifyYaml(draft, { lineWidth: 0 }), 'utf8')

    return {
      id: target.id,
      ok: true,
      outPath,
      elapsedMs: Date.now() - started,
      message: `草稿已写入（intro ${content.intro.length} 字 / archaeology ${content.archaeology.length} 字 / 事件 ${content.events.length} 条 / 文物 ${content.artifacts.length} 件）`,
    }
  } catch (err) {
    return {
      id: target.id,
      ok: false,
      outPath: '',
      elapsedMs: Date.now() - started,
      message: err instanceof Error ? err.message.slice(0, 200) : String(err),
    }
  }
}

/** 批量起草：只处理有来源摘录的条目 */
export async function draftAll(
  targets: readonly DraftTarget[],
  sourcesDir: string,
  outDir: string
): Promise<DraftReport[]> {
  const provider: LlmProvider = new DeepSeekLlm(readEnv())
  const reports: DraftReport[] = []

  for (const target of targets) {
    const sourcePath: string = join(sourcesDir, `${target.id}.md`)
    if (!existsSync(sourcePath)) {
      reports.push({
        id: target.id,
        ok: false,
        outPath: '',
        elapsedMs: 0,
        message: '缺少来源摘录，跳过（先补 packages/data/sources/<id>.md）',
      })
      continue
    }
    const sourceText: string = await readFile(sourcePath, 'utf8')
    const report: DraftReport = await draftOne(provider, target, sourceText, outDir)
    reports.push(report)
    console.log(`  ${report.ok ? 'OK  ' : 'FAIL'} ${report.id.padEnd(22, ' ')} ${report.message}`)
  }

  return reports
}
