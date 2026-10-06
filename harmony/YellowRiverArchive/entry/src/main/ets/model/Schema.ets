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
  // ---- 个人数据（可同步，均带 LWW 元数据）----
  static readonly FAVORITES: string = 'favorites'
  static readonly NOTES: string = 'notes'
  static readonly TAGS: string = 'tags'
  static readonly THEMES: string = 'themes'
  static readonly VISITS: string = 'visits'
  static readonly CONFLICTS: string = 'conflicts'
  static readonly SYNC_META: string = 'sync_meta'
}

/**
 * 可同步表共有的 LWW 列。
 *
 * `deleted` 是**软删除**：若不保留墓碑，设备 A 删除记录后设备 B 推回来的旧版本
 * 会让它“复活”。这是分布式同步里最常见的坑之一。
 */
export const SYNC_COLUMNS: string =
  'updated_at INTEGER NOT NULL, created_at INTEGER NOT NULL, device_id TEXT NOT NULL, deleted INTEGER NOT NULL DEFAULT 0'

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

  // ---- 个人数据 ----
  // 关键设计：favorites 与 visits 的 id **由目标确定性生成**（如 site:ly-erlitou），
  // 而不是随机值。否则两台设备各自收藏同一条目会产生两条记录，
  // LWW 无法把它们收敛成一条，用户会看到重复项。
  // notes 则故意用随机 id：同一目标允许多条笔记，不该被合并。
  `CREATE TABLE IF NOT EXISTS ${Tables.FAVORITES} (
    id TEXT PRIMARY KEY,
    target_type TEXT NOT NULL,
    target_id TEXT NOT NULL,
    tag_ids TEXT NOT NULL DEFAULT '[]',
    ${SYNC_COLUMNS}
  )`,
  `CREATE TABLE IF NOT EXISTS ${Tables.NOTES} (
    id TEXT PRIMARY KEY,
    target_type TEXT NOT NULL,
    target_id TEXT NOT NULL,
    content TEXT NOT NULL,
    ${SYNC_COLUMNS}
  )`,
  `CREATE TABLE IF NOT EXISTS ${Tables.TAGS} (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    preset INTEGER NOT NULL DEFAULT 0,
    ${SYNC_COLUMNS}
  )`,
  `CREATE TABLE IF NOT EXISTS ${Tables.THEMES} (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    target_ids TEXT NOT NULL DEFAULT '[]',
    ${SYNC_COLUMNS}
  )`,
  `CREATE TABLE IF NOT EXISTS ${Tables.VISITS} (
    item_id TEXT PRIMARY KEY,
    visited_at INTEGER NOT NULL,
    ${SYNC_COLUMNS}
  )`,

  // 冲突日志只记录不参与再同步（它是本机观测记录，不是用户数据）
  `CREATE TABLE IF NOT EXISTS ${Tables.CONFLICTS} (
    id TEXT PRIMARY KEY,
    record_id TEXT NOT NULL,
    table_name TEXT NOT NULL,
    local_updated_at INTEGER NOT NULL,
    remote_updated_at INTEGER NOT NULL,
    winner TEXT NOT NULL,
    detected_at INTEGER NOT NULL
  )`,
  `CREATE TABLE IF NOT EXISTS ${Tables.SYNC_META} (
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
  // 同步差量查询走 updated_at：待推送 = updated_at > lastPushedAt
  `CREATE INDEX IF NOT EXISTS idx_favorites_updated ON ${Tables.FAVORITES} (updated_at)`,
  `CREATE INDEX IF NOT EXISTS idx_notes_target ON ${Tables.NOTES} (target_type, target_id)`,
  `CREATE INDEX IF NOT EXISTS idx_notes_updated ON ${Tables.NOTES} (updated_at)`,
  `CREATE INDEX IF NOT EXISTS idx_tags_updated ON ${Tables.TAGS} (updated_at)`,
  `CREATE INDEX IF NOT EXISTS idx_themes_updated ON ${Tables.THEMES} (updated_at)`,
  `CREATE INDEX IF NOT EXISTS idx_visits_updated ON ${Tables.VISITS} (updated_at)`,
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

/**
 * 同步状态键。
 *
 * 待推送条数**不单独建队列表**，而是由 `updated_at > lastPushedAt` 推导。
 * 队列表需要与数据表保持同步，一旦漏更新就会出现“永远推不完”或“改了没推”
 * 的隐形 bug；而时间戳推导是自在自为的，不会与数据脱节。
 */
export class SyncKeys {
  static readonly DEVICE_ID: string = 'deviceId'
  static readonly DEVICE_NAME: string = 'deviceName'
  /** 上次成功推送的游标（毫秒时间戳） */
  static readonly LAST_PUSHED_AT: string = 'lastPushedAt'
  /** 上次成功拉取的游标（服务器时间） */
  static readonly LAST_PULLED_AT: string = 'lastPulledAt'
  static readonly LAST_SYNC_AT: string = 'lastSyncAt'
  static readonly USER_ID: string = 'userId'
}

/** 可同步的表名（顺序即推送顺序，无外键依赖） */
export const SYNCABLE_TABLES: string[] = [
  Tables.TAGS,
  Tables.FAVORITES,
  Tables.NOTES,
  Tables.THEMES,
  Tables.VISITS,
]
