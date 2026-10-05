/**
 * 服务端数据库表结构。
 *
 * 设计前提（ADR-010）：**完整档案与图片只在端侧**，服务端只保留"为检索而切出的
 * 最小切片"——片段文本、分词、向量、图谱关系。因此这里的表刻意不含五层长文。
 *
 * FTS5 的用法：独立虚拟表 + `UNINDEXED` 的 chunk_id，不做外部内容表。
 * 外部内容表需要触发器同步，对一次性导入的场景是多余复杂度。
 */

export const SCHEMA_STATEMENTS: string[] = [
  // ---- 条目（检索与列表用，非完整档案）----
  `CREATE TABLE IF NOT EXISTS items (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    city TEXT NOT NULL,
    era TEXT NOT NULL,
    era_min INTEGER,
    era_max INTEGER,
    types TEXT NOT NULL,
    level TEXT,
    summary TEXT NOT NULL
  )`,
  `CREATE INDEX IF NOT EXISTS idx_items_city ON items(city)`,
  `CREATE INDEX IF NOT EXISTS idx_items_era ON items(era)`,

  // ---- 检索片段 ----
  `CREATE TABLE IF NOT EXISTS chunks (
    id TEXT PRIMARY KEY,
    item_id TEXT NOT NULL,
    section TEXT NOT NULL,
    seq INTEGER NOT NULL,
    text TEXT NOT NULL,
    tokens TEXT NOT NULL
  )`,
  `CREATE INDEX IF NOT EXISTS idx_chunks_item ON chunks(item_id)`,

  // ---- FTS5 关键词索引（分词结果由流水线注入，见 ADR-006）----
  `CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
    chunk_id UNINDEXED,
    tokens
  )`,

  // ---- 向量（从构建期产物导入；启动时全部读进内存做暴力检索，见 ADR-005）----
  `CREATE TABLE IF NOT EXISTS chunk_vectors (
    chunk_id TEXT PRIMARY KEY,
    dim INTEGER NOT NULL,
    vec BLOB NOT NULL
  )`,

  // ---- 图谱（SQLite 两表，不用图数据库，见 ADR-005）----
  `CREATE TABLE IF NOT EXISTS kg_nodes (
    id TEXT PRIMARY KEY,
    type TEXT NOT NULL,
    name TEXT NOT NULL,
    aliases TEXT NOT NULL,
    rank REAL
  )`,
  `CREATE TABLE IF NOT EXISTS kg_edges (
    id TEXT PRIMARY KEY,
    src TEXT NOT NULL,
    dst TEXT NOT NULL,
    rel TEXT NOT NULL,
    weight REAL NOT NULL,
    evidence TEXT
  )`,
  `CREATE INDEX IF NOT EXISTS idx_edges_src ON kg_edges(src)`,
  `CREATE INDEX IF NOT EXISTS idx_edges_dst ON kg_edges(dst)`,
  `CREATE INDEX IF NOT EXISTS idx_nodes_type ON kg_nodes(type)`,

  // ---- 元信息（数据版本、内容哈希）----
  `CREATE TABLE IF NOT EXISTS meta (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
  )`,

  // ---- 调用统计（成本可观测，见 D3-12）----
  `CREATE TABLE IF NOT EXISTS usage_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    operation TEXT NOT NULL,
    tokens INTEGER NOT NULL DEFAULT 0,
    elapsed_ms INTEGER NOT NULL DEFAULT 0,
    ok INTEGER NOT NULL DEFAULT 1,
    created_at INTEGER NOT NULL
  )`,
  `CREATE INDEX IF NOT EXISTS idx_usage_op ON usage_log(operation)`,
]

/** 导入前清空的业务表（保留 FTS5 与 usage_log） */
export const TRUNCATE_STATEMENTS: string[] = [
  `DELETE FROM items`,
  `DELETE FROM chunks`,
  `DELETE FROM chunks_fts`,
  `DELETE FROM chunk_vectors`,
  `DELETE FROM kg_nodes`,
  `DELETE FROM kg_edges`,
]

export class MetaKeys {
  static readonly DATA_VERSION: string = 'dataVersion'
  static readonly CONTENT_HASH: string = 'contentHash'
  static readonly IMPORTED_AT: string = 'importedAt'
  static readonly ITEM_COUNT: string = 'itemCount'
  static readonly CHUNK_COUNT: string = 'chunkCount'
  static readonly EMBEDDING_MODEL: string = 'embeddingModel'
  static readonly EMBEDDING_DIM: string = 'embeddingDim'
}
