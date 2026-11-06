/**
 * 来源摘录采集器。
 *
 * 为什么需要它：`data:draft` 的门禁是「没有 sources/<id>.md 就不起草」（ADR-022）。
 * 75 条摘录如果靠人手抄，一条十分钟，今晚补不完。这个脚本把机械部分自动化：
 * 打开公开页面 → 取正文段落 → 按 sources/README.md 的格式落盘，URL 与访问日期自动带上。
 *
 * 为什么走 playwright-cli 而不是 curl：
 *   - zh.wikipedia.org 与 www.ncha.gov.cn 本机不可达（连续超时，实测）
 *   - baike.baidu.com 可达，但 curl 拿到的只有 2538 字节的反爬页；
 *     真实浏览器渲染后能取到 8-25K 字正文（实测三条：二里头 / 繁塔 / 王城岗）
 *   - playwright-cli 已在 PATH 且浏览器可用，不必再往仓库里塞一个 Playwright 依赖
 *
 * 类名是构建期哈希（para_su_2r / content_DXFtT），所以只匹配前缀，不写全名。
 */

import { spawnSync } from 'node:child_process'
import { existsSync, readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { join } from 'node:path'

import { loadSitesDoc } from './sites'

/** 单条采集结果 */
export interface SourceReport {
  readonly id: string
  readonly name: string
  readonly status: 'ok' | 'thin' | 'fail' | 'mismatch'
  readonly chars: number
  readonly message: string
}

/** 正文太短就不足以支撑起草与查重，标出来交人工 */
const MIN_CHARS: number = 800

/** 浏览器里跑的抽取脚本：摘要 + 正文段落，返回 JSON 字符串 */
const EXTRACT_JS = `(async () => {
  const grab = () => {
    const sum = (document.querySelector('.J-summary') || { innerText: '' }).innerText.trim()
    const paras = [...document.querySelectorAll('[class]')]
      .filter((e) => /(^| )para_/.test(String(e.className)) && /content_/.test(String(e.className)))
      .map((e) => e.innerText.trim())
      .filter((t) => t.length > 25)
    const merged = []
    const seen = new Set()
    for (const p of [sum, ...paras]) {
      const k = p.slice(0, 40)
      if (k.length > 0 && !seen.has(k)) { seen.add(k); merged.push(p) }
    }
    return merged
  }
  // 百科正文是前端渲染的：goto 之后立刻 eval 只会拿到 524 字的导航壳。
  // 轮询到出现正文再返回，最多等 10 秒。
  const deadline = Date.now() + 10000
  let blocks = grab()
  while (blocks.length === 0 && Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, 400))
    blocks = grab()
  }
  return JSON.stringify({ title: document.title, blocks })
})()`

function cli(args: readonly string[], timeoutMs: number): string {
  const run = spawnSync('playwright-cli', [...args], { encoding: 'utf8', timeout: timeoutMs })
  if (run.status !== 0) {
    return ''
  }
  return run.stdout ?? ''
}

/** playwright-cli 把 eval 结果放在 "### Result" 的下一行，且带 JS 字符串引号 */
function parseEval(stdout: string): string {
  const lines = stdout.split('\n')
  const at = lines.findIndex((l) => l.trim() === '### Result')
  if (at < 0 || at + 1 >= lines.length) {
    return ''
  }
  const raw: string = lines[at + 1] ?? ''
  if (raw.length === 0) {
    return ''
  }
  try {
    return String(JSON.parse(raw))
  } catch {
    return raw
  }
}

interface Extracted {
  readonly title: string
  readonly blocks: string[]
}

/**
 * 歧义页的义项链接。
 *
 * 「大相国寺」「函谷关」这类名字在百科是多义词，直接打开 /item/<名字>
 * 会落到只有导航壳的歧义页（实测正文仅 524 字），抓不到任何内容。
 * 歧义页上列着各义项的 /item/<名字>/<编号> 链接与说明文字，
 * 说明里通常带地名 —— 于是按台账里的 city 选义项，选不出再退回第一个。
 */
const SENSE_JS = `(async () => {
  const grab = () => {
    const out = []
    for (const a of document.querySelectorAll('a[href*="/item/"]')) {
      const href = a.getAttribute('href') || ''
      // 用 split + [0-9] 判断，不写 \\d：这段是 TS 模板字符串里的**字符串**，
      // 反斜杠会被 JS 先吃掉一层（\\d 变成 d），页面里拿到的就是坏正则
      const parts = href.split('/')
      if (parts.length < 4 || parts[1] !== 'item') continue
      if (!/^[0-9]+/.test(parts[3])) continue
      const text = a.innerText.trim()
      if (text.includes('编辑') || text.includes('秒懂')) continue
      out.push(href + '||' + text)
    }
    return out.slice(0, 8)
  }
  const deadline = Date.now() + 8000
  let links = grab()
  while (links.length === 0 && Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, 400))
    links = grab()
  }
  return JSON.stringify(links)
})()`

function senseLinks(): string[] {
  const json = parseEval(cli(['eval', SENSE_JS], 120000))
  if (json.length === 0) {
    return []
  }
  try {
    const parsed = JSON.parse(json) as unknown
    return Array.isArray(parsed) ? parsed.map((x) => String(x)) : []
  } catch {
    return []
  }
}

/**
 * 从义项列表里挑一个 —— 只认说明文字命中台账城市的。
 *
 * 不留「取第一个」的兜底：实测那个兜底把「新安汉函谷关」抓成了三门峡的
 * 秦函谷关，把窑址抓成了人物传记。宁可报 mismatch 交人工，也不能写错页。
 */
function pickSense(links: readonly string[], city: string): string {
  const hit = links.find((l) => (l.split('||')[1] ?? '').includes(city))
  if (hit === undefined) {
    return ''
  }
  return `https://baike.baidu.com${hit.split('||')[0]}`
}

function extract(): Extracted {
  const out: Extracted = { title: '', blocks: [] }
  const json = parseEval(cli(['eval', EXTRACT_JS], 120000))
  if (json.length === 0) {
    return out
  }
  try {
    const parsed = JSON.parse(json) as { title?: string; blocks?: string[] }
    return {
      title: parsed.title ?? '',
      blocks: Array.isArray(parsed.blocks) ? parsed.blocks : []
    }
  } catch {
    return out
  }
}

/**
 * 清洗抓来的正文。
 *
 * 为什么要洗：百科把引注写成 `[1]`、`[3-4]` 夹在句子中间。lint 的查重是
 * 「与摘录连续重合 ≥15 字判错」，摘录里插着标记就会把长句切成短串，
 * 等于自己把查重基准打碎 —— 洗掉之后比对才真实。
 * 顺带去掉「播报」「编辑」这类界面残字。
 */
function sanitize(text: string): string {
  return text
    .replace(/\s*\[\d+(?:[-,，]\d+)*\](?:[^\S\n\d])?/g, '')
    .replace(/(?:^|\n)\s*(播报|编辑|讨论\s*\d*|收藏|赞)\s*(?=\n|$)/g, '')
    .replace(/[ \t]{2,}/g, ' ')
    .trim()
}

/** 失败诊断用：当前页面全文长度（0 表示 goto 就没成功） */
function probeBodyLen(): number {
  const out = parseEval(cli(['eval', 'String(document.body.innerText.length)'], 60000))
  const n = Number.parseInt(out, 10)
  return Number.isNaN(n) ? -1 : n
}

function today(): string {
  return new Date().toISOString().slice(0, 10)
}

/**
 * 名称核对。
 *
 * 这条判断是必须的：百科的推荐位与页脚链接里混着完全不相关的词条，
 * 实测有 11 条摘录被写成了「丁建东（复旦材料学者）」和一本小说 ——
 * 数字上都是「29 段 / 2340 字」，不核对就当成抓到内容了。
 * 那种摘录拿去起草，等于把别人的生平写进遗址档案。
 */
function coreName(name: string): string {
  return name.replace(/(遗址|故城|古迹|墓群|段)$/g, '').trim()
}

function coreTitle(title: string): string {
  return title.replace(/_百度百科$/, '').replace(/[（(].*$/, '').trim()
}

/** 返回是否同一实体：核心名互相包含才算数 */
function titleMatches(title: string, name: string): boolean {
  const a: string = coreTitle(title)
  const b: string = coreName(name)
  if (a.length === 0 || b.length === 0) {
    return false
  }
  return a === b || a.includes(b) || b.includes(a)
}

function renderMarkdown(
  name: string,
  url: string,
  data: Extracted,
  matched: boolean,
  viaSense: boolean
): string {
  const note: string[] = []
  if (!matched) {
    note.push(
      `> **需人工确认**：页面标题「${data.title}」与条目名「${name}」不一致，` +
        `可能是同名实体或重定向。起草前请先核对这份摘录是否属于该遗址。`
    )
  }
  if (viaSense) {
    note.push('> 该名字在百科是**多义词**，本页取的是按台账城市筛出的义项，请核对是否同一实体。')
  }
  const head: string = note.length > 0 ? `${note.join('\n>\n')}\n\n` : ''

  return `# ${name} 来源摘录

${head}## 来源 1：百度百科 · ${data.title || name}
- URL: ${url}
- 访问日期: ${today()}

${data.blocks.map((b: string) => sanitize(b)).filter((b: string) => b.length > 20).join('\n\n')}
`
}

/**
 * 采集一批。
 *
 * 串行：playwright-cli 是单浏览器会话，并发会互相抢页面。
 * 每条之间靠 goto 本身隔开，实测一条约 8-10 秒。
 */
export async function fetchSources(opts: {
  indexFile: string
  sourcesDir: string
  onlyMissing: boolean
  onlyId?: string
  limit?: number
}): Promise<SourceReport[]> {
  const doc = await loadSitesDoc(opts.indexFile)
  mkdirSync(opts.sourcesDir, { recursive: true })

  let targets = doc.sites
  if (opts.onlyId !== undefined) {
    targets = targets.filter((s) => s.id === opts.onlyId)
  }
  if (opts.onlyMissing) {
    targets = targets.filter((s) => !existsSync(join(opts.sourcesDir, `${s.id}.md`)))
  }
  if (opts.limit !== undefined) {
    targets = targets.slice(0, opts.limit)
  }

  const reports: SourceReport[] = []
  for (const site of targets) {
    let url = `https://baike.baidu.com/item/${encodeURIComponent(site.name)}`
    cli(['goto', url], 180000)
    let data = extract()
    let chars = data.blocks.reduce((s: number, b: string) => s + sanitize(b).length, 0)

    // 空正文 = 多半是歧义页，按城市选义项再抓一次
    if (chars === 0) {
      const sense: string = pickSense(senseLinks(), site.city)
      if (sense.length > 0) {
        url = sense
        cli(['goto', url], 180000)
        data = extract()
        chars = data.blocks.reduce((s: number, b: string) => s + sanitize(b).length, 0)
      }
    }

    if (chars === 0) {
      // 失败必须说清落在哪个页面：安全验证、404、还是义项也没抓到，
      // 三种情况的处理完全不同，只写「没取到」等于让人重新猜
      reports.push({
        id: site.id,
        name: site.name,
        status: 'fail',
        chars: 0,
        message: `没取到正文｜标题「${data.title.slice(0, 28)}」｜全文 ${probeBodyLen()} 字`,
      })
      continue
    }

    const matched = titleMatches(data.title, site.name)
    // 记下来龙去脉，人工复核时不用猜这几千字是从哪个义项抓的
    const viaSense: boolean = url !== `https://baike.baidu.com/item/${encodeURIComponent(site.name)}`
    const path = join(opts.sourcesDir, `${site.id}.md`)
    writeFileSync(path, renderMarkdown(site.name, url, data, matched, viaSense), 'utf8')

    const status = chars < MIN_CHARS ? 'thin' : 'ok'
    reports.push({
      id: site.id,
      name: site.name,
      status,
      chars,
      message: status === 'thin' ? `正文仅 ${chars} 字，偏薄` : `${data.blocks.length} 段 / ${chars} 字`
    })
  }
  return reports
}
