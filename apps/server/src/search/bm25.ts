/**
 * BM25 关键词检索通道。
 *
 * FTS5 的 bm25() 返回**负数**，越负越相关（SQLite 的约定）。这里统一翻成
 * 「越大越好」的正分数，免得调用方每次都要想一遍符号。
 *
 * 查询串是分词结果之间取 OR 而非 AND：AND 会把「二里头出土的青铜器」
 * 这类长查询压成没有任何结果的死查询，而 BM25 本身就会惩罚只命中部分词的文档。
 */

import type { Db } from '../db/index'

export interface Bm25Hit {
  readonly chunkId: string
  readonly score: number
}

export interface SearchFilter {
  readonly cities?: readonly string[]
  readonly eras?: readonly string[]
  readonly types?: readonly string[]
}

/** 把词转成 FTS5 的安全字面量：双引号包裹，内部引号翻倍 */
function quoteTerm(term: string): string {
  return `"${term.replace(/"/g, '""')}"`
}

/** 组装 FTS5 MATCH 表达式 */
export function buildMatchExpression(tokens: readonly string[]): string {
  const usable: string[] = tokens.filter((t) => t.trim().length > 0)
  if (usable.length === 0) {
    return ''
  }
  return usable.map(quoteTerm).join(' OR ')
}

/** 组装筛选条件（拼进 SQL，值用参数绑定） */
function buildFilterClause(filter: SearchFilter | undefined): { sql: string; args: string[] } {
  const conditions: string[] = []
  const args: string[] = []

  if (filter?.cities !== undefined && filter.cities.length > 0) {
    conditions.push(`i.city IN (${filter.cities.map(() => '?').join(',')})`)
    args.push(...filter.cities)
  }
  if (filter?.eras !== undefined && filter.eras.length > 0) {
    conditions.push(`i.era IN (${filter.eras.map(() => '?').join(',')})`)
    args.push(...filter.eras)
  }
  if (filter?.types !== undefined && filter.types.length > 0) {
    // types 是 JSON 数组字符串，逐个 LIKE（枚举值不含引号，无注入风险）
    const typeConditions: string[] = []
    for (const type of filter.types) {
      typeConditions.push(`i.types LIKE ?`)
      args.push(`%"${type}"%`)
    }
    conditions.push(`(${typeConditions.join(' OR ')})`)
  }

  return {
    sql: conditions.length > 0 ? ` AND ${conditions.join(' AND ')}` : '',
    args,
  }
}

/**
 * BM25 检索。
 *
 * 返回片段级命中——片段是检索与引用的最小单位（见设计文档 4.2），
 * 由调用方再聚合到条目级。
 */
export function searchBm25(
  db: Db,
  tokens: readonly string[],
  topK: number,
  filter?: SearchFilter
): Bm25Hit[] {
  const match: string = buildMatchExpression(tokens)
  if (match.length === 0) {
    return []
  }

  const { sql: filterSql, args: filterArgs } = buildFilterClause(filter)

  const rows = db
    .prepare(
      `SELECT f.chunk_id AS chunkId, bm25(chunks_fts) AS raw
         FROM chunks_fts f
         JOIN chunks c ON c.id = f.chunk_id
         JOIN items i ON i.id = c.item_id
        WHERE chunks_fts MATCH ?${filterSql}
        ORDER BY raw ASC
        LIMIT ?`
    )
    .all(match, ...filterArgs, topK) as unknown as { chunkId: string; raw: number }[]

  return rows.map((row) => ({
    chunkId: row.chunkId,
    // 取负翻正，并限幅到 0 以上：FTS5 偶有 0 分结果，负分会让调用方误判为"负相关"
    score: Math.max(0, -row.raw),
  }))
}
