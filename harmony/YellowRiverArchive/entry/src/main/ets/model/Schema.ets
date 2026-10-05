/**
 * 端侧 RDB 表结构定义。
 *
 * 设计取舍：条目的五层内容结构复杂且读完即用，不适合拆成多表 —— 因此
 * 把"用于筛选与展示的字段"提成独立列，完整的条目 JSON 存在 payload 列里。
 * 这样既能让 SQL 直接完成三维筛选，又不必为内容结构建一堆关联表。
 */

export class Tables {
  static readonly ITEMS: string = 'items'
  static readonly CHUNKS: string = 'chunks'
  static readonly GRAPH_NODES: string = 'graph_nodes'
  static readonly GRAPH_EDGES: string = 'graph_edges'
  static readonly SIMILAR: string = 'similar'
  static readonly META: string = 'meta'
}

/** 建表语句，按依赖顺序执行 */
export const CREATE_STATEMENTS: string[] = [
  `CREATE TABLE IF NOT EXISTS ${Tables.ITEMS} (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    city TEXT NOT NULL,
    era TEXT NOT NULL,
    era_min INTEGER,
    era_max INTEGER,
    types TEXT NOT NULL,
    level TEXT,
    lat REAL,
    lng REAL,
    summary TEXT NOT NULL,
    cover TEXT,
    payload TEXT NOT NULL
  )`,
  `CREATE TABLE IF NOT EXISTS ${Tables.CHUNKS} (
    id TEXT PRIMARY KEY,
    item_id TEXT NOT NULL,
    section TEXT NOT NULL,
    seq INTEGER NOT NULL,
    text TEXT NOT NULL,
    tokens TEXT
  )`,
  `CREATE TABLE IF NOT EXISTS ${Tables.GRAPH_NODES} (
    id TEXT PRIMARY KEY,
    type TEXT NOT NULL,
    name TEXT NOT NULL,
    aliases TEXT,
    rank REAL
  )`,
  `CREATE TABLE IF NOT EXISTS ${Tables.GRAPH_EDGES} (
    id TEXT PRIMARY KEY,
    src TEXT NOT NULL,
    dst TEXT NOT NULL,
    rel TEXT NOT NULL,
    weight REAL NOT NULL,
    evidence TEXT
  )`,
  `CREATE TABLE IF NOT EXISTS ${Tables.SIMILAR} (
    item_id TEXT PRIMARY KEY,
    neighbors TEXT NOT NULL
  )`,
  `CREATE TABLE IF NOT EXISTS ${Tables.META} (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
  )`,
]

/** 索引：为三维筛选与检索加速 */
export const INDEX_STATEMENTS: string[] = [
  `CREATE INDEX IF NOT EXISTS idx_items_city ON ${Tables.ITEMS} (city)`,
  `CREATE INDEX IF NOT EXISTS idx_items_era ON ${Tables.ITEMS} (era)`,
  `CREATE INDEX IF NOT EXISTS idx_chunks_item ON ${Tables.CHUNKS} (item_id)`,
  `CREATE INDEX IF NOT EXISTS idx_chunks_section ON ${Tables.CHUNKS} (section)`,
  `CREATE INDEX IF NOT EXISTS idx_edges_src ON ${Tables.GRAPH_EDGES} (src)`,
  `CREATE INDEX IF NOT EXISTS idx_edges_dst ON ${Tables.GRAPH_EDGES} (dst)`,
]

/** 清空所有业务表（重新导入前调用，保留表结构） */
export const TRUNCATE_STATEMENTS: string[] = [
  `DELETE FROM ${Tables.ITEMS}`,
  `DELETE FROM ${Tables.CHUNKS}`,
  `DELETE FROM ${Tables.GRAPH_NODES}`,
  `DELETE FROM ${Tables.GRAPH_EDGES}`,
  `DELETE FROM ${Tables.SIMILAR}`,
]

/** meta 表键名 */
export class MetaKeys {
  static readonly DATA_VERSION: string = 'dataVersion'
  static readonly CONTENT_HASH: string = 'contentHash'
  static readonly IMPORTED_AT: string = 'importedAt'
  static readonly ITEM_COUNT: string = 'itemCount'
}
