/**
 * 清单台账（sites.yaml）的读取与体检。
 *
 * 与 sites/*.yaml 的区别：sites.yaml 是**清单级元数据**（谁负责、核到什么程度、
 * 正文在哪），sites/*.yaml 才是档案正文。本模块只关心前者。
 *
 * 配套命令：pnpm data:sites
 */

import { readFile } from 'node:fs/promises'

import { parse as parseYaml } from 'yaml'

/** 清单条目 */
export interface SiteEntry {
  readonly id: string
  readonly name: string
  readonly city: string
  readonly era: string
  readonly eraRange?: number[]
  readonly types: string[]
  readonly level: string
  readonly batch?: number
  readonly priority: string
  readonly confidence: string
  readonly status: string
  /** 正文文件相对 packages/data 的路径，尚未撰写时缺省 */
  readonly content?: string
  readonly notes?: string
}

export interface SitesMeta {
  readonly version: string
  readonly updatedAt: string
  readonly totalTarget: number
  readonly allocation: Record<string, number>
  readonly rules: string[]
}

export interface SitesDoc {
  readonly meta: SitesMeta
  readonly sites: SiteEntry[]
}

export async function loadSitesDoc(path: string): Promise<SitesDoc> {
  const raw: string = await readFile(path, 'utf8')
  const parsed = parseYaml(raw) as SitesDoc
  if (parsed === null || typeof parsed !== 'object' || !Array.isArray(parsed.sites)) {
    throw new Error(`${path} 结构不合法：缺少 sites 数组`)
  }
  return parsed
}

function tallyBy(sites: readonly SiteEntry[], pick: (s: SiteEntry) => string): Map<string, number> {
  const map: Map<string, number> = new Map<string, number>()
  for (const s of sites) {
    const key: string = pick(s)
    map.set(key, (map.get(key) ?? 0) + 1)
  }
  return map
}

function formatTally(map: Map<string, number>, order?: readonly string[]): string {
  const entries: [string, number][] = Array.from(map.entries())
  if (order !== undefined) {
    entries.sort((a, b) => {
      const ia: number = order.indexOf(a[0])
      const ib: number = order.indexOf(b[0])
      return (ia < 0 ? 999 : ia) - (ib < 0 ? 999 : ib)
    })
  } else {
    entries.sort((a, b) => b[1] - a[1])
  }
  return entries.map(([k, v]) => `${k} ${v}`).join('  ｜  ')
}

export interface SitesReport {
  readonly lines: string[]
  readonly problems: string[]
}

/** 生成体检报告；problems 非空表示需要处理 */
export function reportSites(doc: SitesDoc, contentDir: string): SitesReport {
  void contentDir
  const lines: string[] = []
  const problems: string[] = []
  const sites: SiteEntry[] = doc.sites

  const target: number = doc.meta.totalTarget
  lines.push(`清单版本 ${doc.meta.version}（更新于 ${doc.meta.updatedAt}）`)
  lines.push(`条目数 ${sites.length} / 目标 ${target}${sites.length === target ? '' : `（差 ${target - sites.length}）`}`)
  if (sites.length !== target) {
    problems.push(`条目数未达目标：${sites.length}/${target}`)
  }

  lines.push(`城市分布   ${formatTally(tallyBy(sites, (s) => s.city), Object.keys(doc.meta.allocation))}`)
  lines.push(`时代分布   ${formatTally(tallyBy(sites, (s) => s.era), ['仰韶', '龙山', '夏商', '周', '汉唐', '宋', '宋以后'])}`)
  lines.push(`优先级     ${formatTally(tallyBy(sites, (s) => s.priority), ['P0', 'P1', 'P2'])}`)
  lines.push(`置信度     ${formatTally(tallyBy(sites, (s) => s.confidence), ['high', 'medium', 'low'])}`)
  lines.push(`核实状态   ${formatTally(tallyBy(sites, (s) => s.status), ['已核', '待核', '存疑'])}`)

  // 城市配额
  for (const [city, quota] of Object.entries(doc.meta.allocation)) {
    const actual: number = sites.filter((s) => s.city === city).length
    if (actual !== quota) {
      problems.push(`城市配额不符：${city} 实际 ${actual}，应为 ${quota}`)
    }
  }

  // id 唯一性
  const ids: Set<string> = new Set<string>()
  const duplicated: string[] = []
  for (const s of sites) {
    if (ids.has(s.id)) {
      duplicated.push(s.id)
    }
    ids.add(s.id)
  }
  if (duplicated.length > 0) {
    problems.push(`id 重复：${duplicated.join('、')}`)
  }

  // 类型覆盖：赛题点名的四类
  const required: readonly string[] = ['都城遗址', '墓葬群', '窑址', '古建筑']
  const typeCount: Map<string, number> = tallyBy(sites.flatMap((s) => s.types.map((t) => ({ ...s, _t: t } as SiteEntry & { _t: string }))), (s) => (s as SiteEntry & { _t: string })._t)
  lines.push(`类型分布   ${formatTally(typeCount)}`)
  for (const t of required) {
    const count: number = typeCount.get(t) ?? 0
    if (count < 6) {
      problems.push(`赛题点名类型不足：${t} 仅 ${count} 条（目标 ≥6）`)
    }
  }

  // P0 批次
  const p0: SiteEntry[] = sites.filter((s) => s.priority === 'P0')
  lines.push('')
  lines.push(`P0 批次 ${p0.length} 条`)
  lines.push(`  城市   ${formatTally(tallyBy(p0, (s) => s.city), Object.keys(doc.meta.allocation))}`)
  lines.push(`  时代   ${formatTally(tallyBy(p0, (s) => s.era), ['仰韶', '龙山', '夏商', '周', '汉唐', '宋', '宋以后'])}`)
  lines.push(`  置信度 ${formatTally(tallyBy(p0, (s) => s.confidence), ['high', 'medium', 'low'])}`)

  const lowInP0: SiteEntry[] = p0.filter((s) => s.confidence === 'low')
  if (lowInP0.length > 0) {
    problems.push(`P0 批次含低置信条目（规则禁止）：${lowInP0.map((s) => s.name).join('、')}`)
  }

  // 尚未撰写正文的 P0 条目
  const p0NoContent: SiteEntry[] = p0.filter((s) => s.content === undefined)
  lines.push(`  已写正文 ${p0.length - p0NoContent.length} / ${p0.length}`)
  if (p0NoContent.length > 0) {
    lines.push(`  待撰写：${p0NoContent.map((s) => s.name).join('、')}`)
  }

  return { lines, problems }
}
