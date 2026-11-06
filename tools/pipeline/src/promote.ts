/**
 * 改写通过的条目入库。
 *
 * 入库不等于核实：这一步只做**结构装配** ——
 * 台账元信息（城市/时代/类型/级别，人工核定过）+ 改写正文 + 来源引用 + 配图，
 * 拼成 sites/<id>.yaml，并把来源与生成方式记进 provenance 台账。
 *
 * 三条硬规矩：
 *   1. 只写 ready/ 里机器验收过零重合的条目；.retry.yaml 一律不入库
 *   2. 已存在的 sites/<id>.yaml 不覆盖（人工撰写的那几条比机器写的贵）
 *   3. 坐标缺省时用城市锚点，并记明是城市级 —— 百科与地理编码源今晚都不可达，
 *      宁可粗，也不要编一个精确到小数点四位的假坐标
 */

import { existsSync, readFileSync, readdirSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

import { parse as parseYaml, stringify as dumpYaml } from 'yaml'

import { loadSitesDoc } from './sites'

/** 与 RiverPath.ets 的城市锚点保持一致 */
const CITY_ANCHOR: Record<string, readonly [number, number]> = {
  三门峡: [34.78, 111.2],
  洛阳: [34.84, 112.44],
  郑州: [34.9, 113.65],
  开封: [34.85, 114.35],
  濮阳: [35.76, 115.03],
}

export interface PromoteReport {
  readonly id: string
  readonly ok: boolean
  readonly message: string
}

interface ProvenanceRow {
  readonly itemId: string
  readonly name: string
  readonly sourceUrls: readonly string[]
  readonly generatedAt: string
  readonly pipeline: string
  readonly geoPrecision: string
}

/** 从 sources/<id>.md 里把来源标题、URL、访问日期读回来 */
function readSourceMeta(path: string): { title: string; url: string; accessedAt: string } {
  const text = readFileSync(path, 'utf8')
  const titleLine = text.match(/^## 来源 1：(.+)$/m)?.[1] ?? '百度百科'
  const url = text.match(/^- URL: (\S+)$/m)?.[1] ?? ''
  const accessedAt = text.match(/^- 访问日期: (\S+)$/m)?.[1] ?? new Date().toISOString().slice(0, 10)
  const title = titleLine.includes('·') ? (titleLine.split('·')[0] ?? titleLine) : titleLine
  return { title: title.trim(), url, accessedAt }
}

export async function promoteAll(opts: {
  readyDir: string
  sourcesDir: string
  sitesDir: string
  indexFile: string
  provenanceFile: string
}): Promise<PromoteReport[]> {
  const doc = await loadSitesDoc(opts.indexFile)
  const byId = new Map<string, (typeof doc.sites)[number]>()
  for (const s of doc.sites) {
    byId.set(s.id, s)
  }

  const reports: PromoteReport[] = []
  const rows: ProvenanceRow[] = []

  const files = readdirSync(opts.readyDir).filter(
    (f) => f.endsWith('.yaml') && !f.endsWith('.retry.yaml')
  )

  for (const f of files) {
    const id = f.replace(/\.yaml$/, '')
    const target = byId.get(id)
    if (target === undefined) {
      reports.push({ id, ok: false, message: '台账里没有这个 id' })
      continue
    }
    const sitePath = join(opts.sitesDir, `${id}.yaml`)
    if (existsSync(sitePath)) {
      reports.push({ id, ok: false, message: '已有正文，不覆盖' })
      continue
    }

    const ready = parseYaml(readFileSync(join(opts.readyDir, f), 'utf8')) as Record<string, unknown>
    const srcPath = join(opts.sourcesDir, `${id}.md`)
    const meta = existsSync(srcPath) ? readSourceMeta(srcPath) : { title: '来源未登记', url: '', accessedAt: '' }
    const anchor = CITY_ANCHOR[target.city] ?? [34.8, 113.6]

    const item: Record<string, unknown> = {
      id,
      name: target.name,
      aliases: [],
      city: target.city,
      era: target.era,
      ...(target.eraRange !== undefined ? { eraRange: target.eraRange } : {}),
      types: target.types,
      level: target.level,
      geo: { lat: anchor[0], lng: anchor[1] },
      summary: ready.summary ?? '',
      intro: ready.intro ?? '',
      archaeology: ready.archaeology ?? '',
      events: ready.events ?? [],
      poems: ready.poems ?? [],
      ...(ready.travel !== undefined ? { travel: ready.travel } : {}),
      artifacts: ready.artifacts ?? [],
      figures: ready.figures ?? [],
      keywords: ready.keywords ?? [],
      images: [
        {
          url: `img/${id}-1.webp`,
          caption: `${target.name}示意图 · 本项目绘制`,
          credit: '本项目绘制',
          license: '自有版权（示意插图）',
        },
      ],
      sources: meta.url.length > 0 ? [meta] : [],
    }

    // 必填字段缺失就别写，让 data:build 的校验去报，而不是塞一个半成品进 sites/
    const required: string[] = ['summary', 'intro', 'archaeology']
    const missing = required.filter((k) => String(item[k] ?? '').length < 40)
    if (missing.length > 0) {
      reports.push({ id, ok: false, message: `字段过短或缺失：${missing.join('、')}` })
      continue
    }

    writeFileSync(sitePath, dumpYaml(item), 'utf8')
    rows.push({
      itemId: id,
      name: target.name,
      sourceUrls: meta.url.length > 0 ? [meta.url] : [],
      generatedAt: new Date().toISOString(),
      pipeline: '来源摘录 → AI 起草 → AI 改写（15 字重合机器验收）→ 结构装配',
      geoPrecision: '城市锚点（非遗址实测坐标）',
    })
    reports.push({ id, ok: true, message: '已入库' })
  }

  // 台账：补 content 指向，并把 sources URL 写进去（规则要求每条有可访问来源链接）
  if (rows.length > 0) {
    let index = readFileSync(opts.indexFile, 'utf8')
    for (const row of rows) {
      index = addContentRef(index, row.itemId, row.sourceUrls[0] ?? '')
    }
    writeFileSync(opts.indexFile, index, 'utf8')
  }

  // provenance 台账：仓库里留着，不进 HAP、不在 UI 出现
  const prev = existsSync(opts.provenanceFile)
    ? (JSON.parse(readFileSync(opts.provenanceFile, 'utf8')) as { entries: ProvenanceRow[] })
    : { entries: [] as ProvenanceRow[] }
  const known = new Set(prev.entries.map((e) => e.itemId))
  prev.entries = [...prev.entries, ...rows.filter((r) => !known.has(r.itemId))]
  writeFileSync(opts.provenanceFile, JSON.stringify(prev, null, 2), 'utf8')

  return reports
}

/**
 * 往台账里给某个条目补 `content:` 与 `sources:` 两行。
 *
 * 用文本插入而不是 yaml.dump 整份文件：台账头部有注释与规则说明，
 * 重新序列化会把它们全部丢掉 —— 那是这份文件的立身之本。
 */
function addContentRef(index: string, id: string, url: string): string {
  const blockStart = index.indexOf(`  - id: ${id}\n`)
  if (blockStart < 0) {
    return index
  }
  let next = index.indexOf('\n  - id: ', blockStart + 1)
  if (next < 0) {
    next = index.length
  }
  let block = index.slice(blockStart, next)
  if (!block.includes('content:')) {
    block = block.replace(/\n$/, `\n    content: sites/${id}.yaml\n`)
  }
  if (url.length > 0 && !block.includes('sourceUrl:')) {
    block = block.replace(/\n$/, `    sourceUrl: ${url}\n`)
  }
  return index.slice(0, blockStart) + block + index.slice(next)
}
