/**
 * 条目仓储。
 *
 * payload 列直接存端侧要的 HeritageItem 形状，列表接口只取轻量列 ——
 * 列表页不需要正文，避免一次查询把 80 条长文全拖出来。
 */

import type { HeritageItem, HeritageSummary, ItemListResponse, SimilarNeighbor } from '@yra/shared'

import type { Db } from '../db/index'
import type { VectorStore } from '../search/vectors'

interface ItemRow {
  readonly id: string
  readonly name: string
  readonly city: string
  readonly era: string
  readonly types: string
  readonly level: string
  readonly summary: string
  readonly cover: string
}

export interface ItemListParams {
  readonly city?: string
  readonly era?: string
  readonly type?: string
  readonly page: number
  readonly pageSize: number
}

export function listItems(db: Db, params: ItemListParams): ItemListResponse {
  const where: string[] = []
  const args: (string | number)[] = []

  if (params.city !== undefined && params.city.length > 0) {
    where.push('city = ?')
    args.push(params.city)
  }
  if (params.era !== undefined && params.era.length > 0) {
    where.push('era = ?')
    args.push(params.era)
  }
  if (params.type !== undefined && params.type.length > 0) {
    // types 是 JSON 数组字符串；枚举值不含引号，LIKE 足够且不引入 FTS 开销
    where.push('types LIKE ?')
    args.push(`%"${params.type}"%`)
  }

  const clause: string = where.length > 0 ? `WHERE ${where.join(' AND ')}` : ''
  const total: number = (
    db.prepare(`SELECT COUNT(*) AS n FROM items ${clause}`).get(...args) as { n: number }
  ).n

  const offset: number = (params.page - 1) * params.pageSize
  const rows = db
    .prepare(
      `SELECT id, name, city, era, types, level, summary, cover
         FROM items ${clause}
        ORDER BY era_min ASC, id ASC
        LIMIT ? OFFSET ?`
    )
    .all(...args, params.pageSize, offset) as unknown as ItemRow[]

  const items: HeritageSummary[] = rows.map((row) => ({
    id: row.id,
    name: row.name,
    city: row.city as HeritageSummary['city'],
    era: row.era as HeritageSummary['era'],
    types: JSON.parse(row.types) as HeritageSummary['types'],
    level: row.level.length > 0 ? (row.level as HeritageSummary['level']) : undefined,
    summary: row.summary,
    cover: row.cover.length > 0 ? row.cover : undefined,
  }))

  return { total, page: params.page, pageSize: params.pageSize, items }
}

export function getItem(db: Db, id: string): HeritageItem | undefined {
  const row = db.prepare('SELECT payload FROM items WHERE id = ?').get(id) as
    | { payload: string }
    | undefined
  return row === undefined ? undefined : (JSON.parse(row.payload) as HeritageItem)
}

export function itemExists(db: Db, id: string): boolean {
  return db.prepare('SELECT 1 FROM items WHERE id = ?').get(id) !== undefined
}

/**
 * 关联推荐：用条目的「片段向量均值」作为该条目的语义指纹，再做一轮点积检索。
 *
 * 为什么用均值而不是主图/首片：一个条目包含 intro/archaeology/events…
 * 多个片段，取均值能得到"整条在语义空间的中心"；只用首片会让推荐偏向引言。
 */
export function relatedItems(
  db: Db,
  vectors: VectorStore,
  itemId: string,
  limit: number
): SimilarNeighbor[] {
  const rows = db.prepare('SELECT id FROM chunks WHERE item_id = ? ORDER BY seq ASC').all(itemId) as {
    id: string
  }[]
  if (rows.length === 0) {
    return []
  }

  const dim: number = vectors.dimension
  if (dim === 0) {
    return []
  }

  const mean = new Float32Array(dim)
  let used: number = 0
  for (const row of rows) {
    const vec: Float32Array | undefined = vectors.get(row.id)
    if (vec === undefined) {
      continue
    }
    for (let d = 0; d < dim; d += 1) {
      mean[d] = (mean[d] ?? 0) + (vec[d] ?? 0)
    }
    used += 1
  }
  if (used === 0) {
    return []
  }

  // 归一化，使点积即余弦
  let norm: number = 0
  for (let d = 0; d < dim; d += 1) {
    const v: number = mean[d] ?? 0
    norm += v * v
  }
  norm = Math.sqrt(norm)
  if (norm === 0) {
    return []
  }
  for (let d = 0; d < dim; d += 1) {
    mean[d] = (mean[d] ?? 0) / norm
  }

  const self = getItem(db, itemId)
  const chunkToItem = new Map<string, string>()
  for (const row of db.prepare('SELECT id, item_id FROM chunks').all() as {
    id: string
    item_id: string
  }[]) {
    chunkToItem.set(row.id, row.item_id)
  }

  // 取足够多的片段候选，再按条目聚合为「每条最高分」
  const hits = vectors.search(mean, Math.min(limit * 8 + 8, 200))
  const bestByItem = new Map<string, number>()
  for (const hit of hits) {
    const owner: string | undefined = chunkToItem.get(hit.chunkId)
    if (owner === undefined || owner === itemId) {
      continue
    }
    const prev: number | undefined = bestByItem.get(owner)
    if (prev === undefined || hit.score > prev) {
      bestByItem.set(owner, hit.score)
    }
  }

  const ranked = [...bestByItem.entries()].sort((a, b) => b[1] - a[1]).slice(0, limit)
  const out: SimilarNeighbor[] = []
  for (const [id, score] of ranked) {
    const other = getItem(db, id)
    if (other === undefined) {
      continue
    }
    out.push({ id, score: Math.round(score * 10000) / 10000, reason: explain(self, other) })
  }
  return out
}

/** 生成可解释的推荐理由：优先说共同点，说不出来才退回语义相近 */
function explain(a: HeritageItem | undefined, b: HeritageItem): string {
  const reasons: string[] = []
  if (a !== undefined) {
    if (a.city === b.city) {
      reasons.push(`同属${b.city}`)
    }
    const sharedType: string | undefined = b.types.find((t) => a.types.includes(t))
    if (sharedType !== undefined) {
      reasons.push(`同为${sharedType}`)
    }
    const sharedEra: boolean = a.era === b.era
    if (sharedEra && reasons.length < 2) {
      reasons.push(`同属${b.era}时期`)
    }
  }
  if (reasons.length === 0) {
    return '内容相近'
  }
  return reasons.slice(0, 2).join(' · ')
}
