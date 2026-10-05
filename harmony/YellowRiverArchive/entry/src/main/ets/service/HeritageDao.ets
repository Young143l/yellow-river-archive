import { common } from '@kit.AbilityKit'
import { relationalStore } from '@kit.ArkData'

import type { City, Era, HeritageItem, HeritageType, SimilarNeighbor } from '../shared'
import { Tables } from '../model/Schema'
import { DataImportService } from './DataImportService'

/** 列表项：只带列表页需要的字段，避免把长文读进内存 */
export interface HeritageSummary {
  readonly id: string
  readonly name: string
  readonly city: City
  readonly era: Era
  readonly types: string[]
  readonly level: string
  readonly summary: string
  readonly cover: string
}

/** 关联推荐项 */
export interface RelatedItem {
  readonly id: string
  readonly name: string
  readonly score: number
  readonly reason: string
}

/** 筛选条件 */
export interface HeritageFilter {
  readonly cities?: string[]
  readonly eras?: string[]
  readonly types?: string[]
}

/** 按时代分组的计数（时间轴用） */
export interface EraCount {
  readonly era: string
  readonly count: number
}

function typesFromPayload(item: HeritageItem): string[] {
  const result: string[] = []
  for (const t of item.types) {
    result.push(t as string)
  }
  return result
}

/**
 * 档案数据访问。
 *
 * 条目总数只有 80 条，因此一次性读进内存并缓存：筛选、检索都在内存里做，
 * 比每次拼 SQL 更快也更简单。RDB 仍是持久化与离线存储的落点。
 */
export class HeritageDao {
  private static items: HeritageItem[] | undefined = undefined
  private static byId: Map<string, HeritageItem> = new Map<string, HeritageItem>()

  /** 预热：确保数据已导入并把条目读进缓存 */
  static async ready(context: common.Context): Promise<void> {
    await DataImportService.ensureImported(context)
    if (HeritageDao.items !== undefined) {
      return
    }
    const store: relationalStore.RdbStore = await DataImportService.open(context)
    const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(Tables.ITEMS)
    predicates.orderByAsc('id')
    const rs: relationalStore.ResultSet = await store.query(predicates, ['payload'])

    const list: HeritageItem[] = []
    const index: Map<string, HeritageItem> = new Map<string, HeritageItem>()
    const payloadCol: number = rs.getColumnIndex('payload')
    while (rs.goToNextRow()) {
      const item: HeritageItem = JSON.parse(rs.getString(payloadCol)) as HeritageItem
      list.push(item)
      index.set(item.id, item)
    }
    rs.close()

    HeritageDao.items = list
    HeritageDao.byId = index
  }

  static all(): HeritageItem[] {
    return HeritageDao.items !== undefined ? HeritageDao.items : []
  }

  static count(): number {
    return HeritageDao.all().length
  }

  static summaryOf(item: HeritageItem): HeritageSummary {
    return {
      id: item.id,
      name: item.name,
      city: item.city,
      era: item.era,
      types: typesFromPayload(item),
      level: item.level !== undefined ? item.level : '',
      summary: item.summary,
      cover: item.images.length > 0 ? item.images[0].url : '',
    }
  }

  /** 按筛选条件取列表；不传条件即全量 */
  static list(filter?: HeritageFilter): HeritageSummary[] {
    const result: HeritageSummary[] = []
    for (const item of HeritageDao.all()) {
      if (filter !== undefined) {
        if (filter.cities !== undefined && filter.cities.length > 0) {
          if (!filter.cities.includes(item.city as string)) {
            continue
          }
        }
        if (filter.eras !== undefined && filter.eras.length > 0) {
          if (!filter.eras.includes(item.era as string)) {
            continue
          }
        }
        if (filter.types !== undefined && filter.types.length > 0) {
          let hit: boolean = false
          for (const t of item.types) {
            if (filter.types.includes(t as string)) {
              hit = true
              break
            }
          }
          if (!hit) {
            continue
          }
        }
      }
      result.push(HeritageDao.summaryOf(item))
    }
    return result
  }

  static byEra(era: string): HeritageSummary[] {
    const result: HeritageSummary[] = []
    for (const item of HeritageDao.all()) {
      if ((item.era as string) === era) {
        result.push(HeritageDao.summaryOf(item))
      }
    }
    return result
  }

  /** 各时代的条目数，用于时间轴刻度 */
  static eraCounts(): EraCount[] {
    const map: Map<string, number> = new Map<string, number>()
    for (const item of HeritageDao.all()) {
      const key: string = item.era as string
      map.set(key, (map.get(key) ?? 0) + 1)
    }
    const result: EraCount[] = []
    map.forEach((count: number, era: string) => {
      result.push({ era, count })
    })
    return result
  }

  static detail(id: string): HeritageItem | undefined {
    return HeritageDao.byId.get(id)
  }

  /** 关联推荐（读构建期预计算的邻居，离线可用且理由可解释） */
  static async related(context: common.Context, itemId: string): Promise<RelatedItem[]> {
    await HeritageDao.ready(context)
    const store: relationalStore.RdbStore = await DataImportService.open(context)
    const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(Tables.SIMILAR)
    predicates.equalTo('item_id', itemId)
    const rs: relationalStore.ResultSet = await store.query(predicates, ['neighbors'])
    let raw: string = ''
    if (rs.goToNextRow()) {
      raw = rs.getString(rs.getColumnIndex('neighbors'))
    }
    rs.close()
    if (raw.length === 0) {
      return []
    }

    const neighbors: SimilarNeighbor[] = JSON.parse(raw) as SimilarNeighbor[]
    const result: RelatedItem[] = []
    for (const n of neighbors) {
      const target: HeritageItem | undefined = HeritageDao.byId.get(n.id)
      if (target !== undefined) {
        result.push({
          id: n.id,
          name: target.name,
          score: n.score,
          reason: n.reason,
        })
      }
    }
    return result
  }
}
