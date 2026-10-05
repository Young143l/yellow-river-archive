/**
 * 读取并校验档案源文件。
 *
 * 源文件：packages/data/sites/<id>.yaml，一条档案一个文件。
 * 校验依据：@yra/shared 的 HeritageItemSchema（ArkTS 子集写法的同一份契约）。
 */

import { readdir, readFile } from 'node:fs/promises'
import { join } from 'node:path'

import { HeritageItemSchema, type HeritageItem } from '@yra/shared'
import { parse as parseYaml } from 'yaml'

export interface LoadIssue {
  readonly file: string
  readonly problems: readonly string[]
}

export interface LoadResult {
  readonly items: HeritageItem[]
  readonly issues: LoadIssue[]
}

/**
 * 读取目录下全部 .yaml 档案。
 * 单条出错不影响其他条目，问题统一收集后由调用方决定是否阻断。
 */
export async function loadSites(dir: string): Promise<LoadResult> {
  const entries: string[] = await readdir(dir)
  const files: string[] = entries.filter((f) => f.endsWith('.yaml') || f.endsWith('.yml')).sort()

  const items: HeritageItem[] = []
  const issues: LoadIssue[] = []
  const seenIds: Set<string> = new Set()

  for (const file of files) {
    const raw: string = await readFile(join(dir, file), 'utf8')
    let parsed: unknown
    try {
      parsed = parseYaml(raw)
    } catch (err) {
      issues.push({ file, problems: [`YAML 解析失败：${(err as Error).message}`] })
      continue
    }

    const result = HeritageItemSchema.safeParse(parsed)
    if (!result.success) {
      issues.push({
        file,
        problems: result.error.issues.map((i) => `${i.path.join('.')}: ${i.message}`),
      })
      continue
    }

    const item: HeritageItem = result.data
    if (seenIds.has(item.id)) {
      issues.push({ file, problems: [`id 重复：${item.id}`] })
      continue
    }
    seenIds.add(item.id)
    items.push(item)
  }

  return { items, issues }
}

/** 数据分布统计，用于 status 命令与覆盖度校验 */
export interface Distribution {
  readonly byCity: { readonly key: string; readonly count: number }[]
  readonly byEra: { readonly key: string; readonly count: number }[]
  readonly byType: { readonly key: string; readonly count: number }[]
  readonly total: number
  readonly imageCount: number
  readonly poemCovered: number
}

export function computeDistribution(items: readonly HeritageItem[]): Distribution {
  const tally = (keys: readonly string[], pick: (item: HeritageItem) => readonly string[]) => {
    const map = new Map<string, number>()
    for (const key of keys) {
      map.set(key, 0)
    }
    for (const item of items) {
      for (const key of pick(item)) {
        map.set(key, (map.get(key) ?? 0) + 1)
      }
    }
    return Array.from(map.entries()).map(([key, count]) => ({ key, count }))
  }

  const cityKeys: readonly string[] = ['洛阳', '郑州', '开封', '三门峡', '濮阳']
  const eraKeys: readonly string[] = ['仰韶', '龙山', '夏商', '周', '汉唐', '宋', '宋以后']

  const typeSet: Set<string> = new Set()
  for (const item of items) {
    for (const t of item.types) {
      typeSet.add(t)
    }
  }

  let imageCount: number = 0
  let poemCovered: number = 0
  for (const item of items) {
    imageCount += item.images.length
    if (item.poems.length > 0) {
      poemCovered += 1
    }
  }

  return {
    byCity: tally(cityKeys, (i) => [i.city]),
    byEra: tally(eraKeys, (i) => [i.era]),
    byType: tally(Array.from(typeSet).sort(), (i) => i.types),
    total: items.length,
    imageCount,
    poemCovered,
  }
}
