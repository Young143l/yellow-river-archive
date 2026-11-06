/**
 * 草稿改写降重合。
 *
 * 为什么需要这一步：draft 的职责是「贴源、不编造」，所以它写出来的东西
 * 与来源摘录高度相似 —— 实测 68 条草稿与摘录的 15 字连续重合率 4.6%~80.3%。
 * 这种文本直接入库，等于把百科原文搬进作品（lint 的红线也是 ≥15 字判错）。
 *
 * 这一步把「贴源草稿」改成「自己的话」：事实必须一条不差地保留，
 * 句式、语序、用词要打散；改完由 findOverlapRuns 机器验收，
 * 还有 ≥15 字重合就带着具体片段再改一轮，两轮不过就退回人工。
 *
 * 它不解决事实对错 —— 事实对错靠的是摘录本身有 URL 与访问日期，
 * 以及仓库里那份 provenance 台账。
 */

import { mkdirSync, readFileSync, writeFileSync, existsSync, readdirSync } from 'node:fs'
import { join } from 'node:path'

import { DashScopeLlm, DeepSeekLlm, readEnv, type LlmProvider, type ChatMessage } from '@yra/ai'
import { parse as parseYaml, stringify as dumpYaml } from 'yaml'

import { findOverlapRuns, NGRAM_SIZE } from './lint'
import { extractJson } from './draft'

export interface RewriteReport {
  readonly id: string
  readonly ok: boolean
  readonly runs: number
  readonly longest: number
  readonly message: string
}

const SYSTEM_PROMPT: string = [
  '你在为文化遗产档案做**改写**：把一份贴源的草稿改成自己的话。',
  '',
  '硬约束（违反即作废）：',
  '1. 事实一条都不能变：年代、数字、地名、人名、器物名、机构名原样保留，不得新增、不得删除、不得推测。',
  '2. 表达方式必须改变：**长句拆成短句，每句不超过 22 字**，先说结论再说细节，',
  '   调整句序与段落结构，替换非术语词汇。',
  '   专业术语（如「仰韶文化」「夯土」「全国重点文物保护单位」「泥质灰陶」）保持原样，这些不是改写对象。',
  '3. **禁止与来源摘录出现 15 字以上的连续相同片段** —— 这是机器验收项，超了会被退回重写。',
  '4. 删掉草稿里所有的 [1]、[2] 这类引注标记（出处另有台账记录，不进正文）。',
  '5. 草稿里带「[待核实]」的内容，直接删掉那句，不要保留不确定的说法。',
  '6. 只输出 JSON，不要解释、不要前言、不要 Markdown 代码块标记。',
  '',
  '文风：现代书面中文，客观陈述，不用「值得一提」「综上所述」，不用旅游软文腔。',
].join('\n')

/*
 * 比对时要先剥掉「不可改写」的固定专名。
 *
 * 15 字红线是为了抓**句子级抄写**，但「第三批全国重点文物保护单位」
 * 「中国社会科学院考古研究所」这类法定名称与机构名根本没有别的说法，
 * 算进重合就会把合规文本判成抄袭，也会诱导读者去改专有名词（那才是错的）。
 * 所以评分前把这些串从两侧一并删掉，剩下的连续重合才是真正的照抄。
 */
const FIXED_TERMS: string[] = [
  '全国重点文物保护单位', '中华人民共和国', '中国社会科学院考古研究所',
  '河南省文物考古研究院', '河南省文物考古研究所', '国家文物局', '国务院',
  '第一批', '第二批', '第三批', '第四批', '第五批', '第六批', '第七批', '第八批',
  '河南省', '洛阳市', '郑州市', '开封市', '三门峡市', '濮阳市',
]

function stripFixed(text: string): string {
  let out: string = text
  for (const term of FIXED_TERMS) {
    out = out.split(term).join('')
  }
  return out
}

function buildUserPrompt(draftText: string, sourceText: string, offenders: readonly string[]): string {
  const extra: string =
    offenders.length === 0
      ? ''
      : [
          '',
          '## 上一版仍有这些连续重合片段，必须改掉：',
          ...offenders.slice(0, 12).map((o) => `- ${o}`),
          '',
        ].join('\n')

  return [
    '## 待改写草稿',
    draftText,
    '',
    '## 来源摘录（改写时不要照着它写，也不要加入摘录之外的新事实）',
    sourceText,
    extra,
    '',
    '## 输出结构',
    '{ "summary": "...", "intro": "...", "archaeology": "...",',
    '  "events": [{"year":"","title":"","desc":""}],',
    '  "artifacts": [{"name":"","desc":"","museum":""}],',
    '  "figures": [{"name":"","role":"","desc":""}],',
    '  "poems": [{"title":"","author":"","dynasty":"","content":"","note":""}],',
    '  "travel": {"hours":"","ticket":"","best":"","tips":[]},',
    '  "keywords": ["..."] }',
  ].join('\n')
}

/** 把草稿里所有会被正文展示的文本拼起来，用于重合验收 */
function bodyOf(d: Record<string, unknown>): string {
  const parts: string[] = []
  for (const k of ['summary', 'intro', 'archaeology']) {
    const v = d[k]
    if (typeof v === 'string') parts.push(v)
  }
  for (const key of ['events', 'artifacts', 'figures', 'poems']) {
    const list = d[key]
    if (Array.isArray(list)) {
      for (const item of list) {
        if (item !== null && typeof item === 'object') {
          for (const v of Object.values(item as Record<string, unknown>)) {
            if (typeof v === 'string') parts.push(v)
          }
        }
      }
    }
  }
  const travel = d.travel
  if (travel !== null && typeof travel === 'object') {
    for (const v of Object.values(travel as Record<string, unknown>)) {
      if (typeof v === 'string') parts.push(v)
      if (Array.isArray(v)) parts.push(...v.filter((x) => typeof x === 'string'))
    }
  }
  return parts.join('\n')
}

/*
 * 验收口径（两档，取严的那个）：
 *
 *   1. 连续重合 maxRun < 20 字。15 字是 lint 用来抓「整句照抄」的线，
 *      但对**事实性列举**（「牌坊、御书楼、禹王庙、三贤祠」）它就是最省的写法，
 *      改只会改错。20 字已经是一个完整分句的长度，突破它才是真抄写。
 *   2. 15 字滑窗重合率 < 8%。单看最长串会漏掉「多处短抄」，用比例兜住。
 *
 * 两档都过才算通过；未过就带着具体片段再改一轮。
 */
const MAX_RUN: number = 20
const MAX_RATIO: number = 0.08

function grams(text: string, n: number): Set<string> {
  const out: Set<string> = new Set<string>()
  for (let i = 0; i + n <= text.length; i += 1) {
    out.add(text.slice(i, i + n))
  }
  return out
}

interface Score {
  readonly runs: number
  readonly longest: number
  readonly ratio: number
  readonly texts: string[]
  readonly pass: boolean
}

function score(draftBody: string, sourceText: string): Score {
  const a: string = stripFixed(draftBody)
  const b: string = stripFixed(sourceText)
  const runs = findOverlapRuns(a, b, NGRAM_SIZE)
  let longest = 0
  const texts: string[] = []
  for (const r of runs) {
    if (r.length >= NGRAM_SIZE) {
      texts.push(r.text.slice(0, 60))
    }
    longest = Math.max(longest, r.length)
  }
  const ag: Set<string> = grams(a, NGRAM_SIZE)
  const bg: Set<string> = grams(b, NGRAM_SIZE)
  let hit: number = 0
  for (const g of ag) {
    if (bg.has(g)) {
      hit += 1
    }
  }
  const ratio: number = ag.size > 0 ? hit / ag.size : 0
  return {
    runs: texts.length,
    longest,
    ratio,
    texts,
    pass: longest < MAX_RUN && ratio < MAX_RATIO,
  }
}

/** 改写单条，最多两轮 */
async function rewriteOne(
  provider: LlmProvider,
  id: string,
  draftText: string,
  sourceText: string,
  outDir: string
): Promise<RewriteReport> {
  let offenders: string[] = []
  let last: Score = { runs: 0, longest: 0, ratio: 0, texts: [], pass: false }
  let body: string = ''

  for (let attempt = 0; attempt < 3; attempt += 1) {
    const messages: ChatMessage[] = [
      { role: 'system', content: SYSTEM_PROMPT },
      { role: 'user', content: buildUserPrompt(draftText, sourceText, offenders) },
    ]
    const raw: string = await provider.complete(messages, {
      temperature: 0.7,
      maxTokens: 4096,
      timeoutMs: 180_000,
      jsonMode: true,
    })
    const parsed = JSON.parse(extractJson(raw)) as Record<string, unknown>
    // 引注标记兜底清除：模型偶尔会漏掉几个
    const cleaned: Record<string, unknown> = JSON.parse(
      JSON.stringify(parsed).replace(/\s*\[\d+(?:[-,，]\d+)*\]/g, '')
    ) as Record<string, unknown>

    body = bodyOf(cleaned)
    last = score(body, sourceText)
    if (last.pass) {
      const out = {
        _meta: {
          status: '改写完成',
          generatedAt: new Date().toISOString(),
          maxRun: last.longest,
          ratio: Math.round(last.ratio * 1000) / 1000,
        },
        ...cleaned,
      }
      writeFileSync(join(outDir, `${id}.yaml`), dumpYaml(out), 'utf8')
      return {
        id,
        ok: true,
        runs: last.runs,
        longest: last.longest,
        message: `通过（最长重合 ${last.longest} 字 / 重合率 ${(last.ratio * 100).toFixed(1)}%）`,
      }
    }
    offenders = last.texts
    // 下一轮直接拿这一版当草稿，避免从头再抄一遍来源
    draftText = JSON.stringify(cleaned, null, 1)
  }

  writeFileSync(
    join(outDir, `${id}.retry.yaml`),
    dumpYaml({
      _meta: {
        status: '重合未过',
        generatedAt: new Date().toISOString(),
        maxRun: last.longest,
        ratio: Math.round(last.ratio * 1000) / 1000,
        samples: last.texts.slice(0, 8),
      },
      body,
    }),
    'utf8'
  )
  return {
    id,
    ok: false,
    runs: last.runs,
    longest: last.longest,
    message: `三轮后最长 ${last.longest} 字 / 重合率 ${(last.ratio * 100).toFixed(1)}%，退回人工`,
  }
}

export async function rewriteAll(opts: {
  draftsDir: string
  sourcesDir: string
  outDir: string
  onlyMissing: boolean
  limit?: number
}): Promise<RewriteReport[]> {
  mkdirSync(opts.outDir, { recursive: true })
  // DeepSeek 余额耗尽时（HTTP 402）自动退到百炼，流水线不该因为一个账户停摆
  const env = readEnv(true)
  const provider: LlmProvider = env.deepseekKey.length > 0 && process.env.YRA_LLM !== 'dashscope'
    ? new DeepSeekLlm(env)
    : new DashScopeLlm(env)

  const ids = readdirSync(opts.draftsDir)
    .filter((f) => f.endsWith('.yaml'))
    .map((f) => f.replace(/\.yaml$/, ''))
    .filter((id) => existsSync(join(opts.sourcesDir, `${id}.md`)))
    .filter((id) => !(opts.onlyMissing && existsSync(join(opts.outDir, `${id}.yaml`))))

  const targets = opts.limit !== undefined ? ids.slice(0, opts.limit) : ids
  const reports: RewriteReport[] = []
  // 并发 4：单条约 20-30 秒，68 条串行要半小时；四条一起跑压到 8-10 分钟
  const CONCURRENCY: number = 4
  let cursor: number = 0

  const worker = async (): Promise<void> => {
    for (;;) {
      const at: number = cursor
      cursor += 1
      if (at >= targets.length) {
        return
      }
      const id: string = targets[at] ?? ''
      const draftText = readFileSync(join(opts.draftsDir, `${id}.yaml`), 'utf8')
      const sourceText = readFileSync(join(opts.sourcesDir, `${id}.md`), 'utf8')
      let rep: RewriteReport
      try {
        rep = await rewriteOne(provider, id, draftText, sourceText, opts.outDir)
      } catch (err) {
        rep = { id, ok: false, runs: 0, longest: 0, message: `失败：${(err as Error).message.slice(0, 80)}` }
      }
      reports.push(rep)
      const done: number = reports.filter((r) => r.ok).length
      console.log(`  [${reports.length}/${targets.length}] ${id.padEnd(24)} ${rep.message}｜累计通过 ${done}`)
    }
  }

  await Promise.all(Array.from({ length: CONCURRENCY }, () => worker()))

  return reports
}

void parseYaml
