import { common } from '@kit.AbilityKit'
import { relationalStore } from '@kit.ArkData'
import { util } from '@kit.ArkTS'

import type { Chunk, HeritageItem, PresetMeta, SimilarEntry } from '../shared'
import { CREATE_STATEMENTS, INDEX_STATEMENTS, MetaKeys, Tables, TRUNCATE_STATEMENTS } from '../model/Schema'

export interface ImportReport {
  readonly skipped: boolean
  readonly dataVersion: string
  readonly itemCount: number
  readonly chunkCount: number
  readonly elapsedMs: number
}

const STORE_NAME: string = 'yra.db'
const RAW_DIR: string = 'data'

/**
 * 预置数据导入服务。
 *
 * 首次启动时把 rawfile/data 下的预置包导入 RDB；之后启动通过 meta.dataVersion
 * 比对直接跳过。并发调用共享同一个导入 Promise，避免重复导入。
 */
export class DataImportService {
  private static store: relationalStore.RdbStore | undefined = undefined
  private static importing: Promise<ImportReport> | undefined = undefined

  /** 打开（并初始化）RDB，全局复用同一个实例 */
  static async open(context: common.Context): Promise<relationalStore.RdbStore> {
    if (DataImportService.store !== undefined) {
      return DataImportService.store
    }
    const config: relationalStore.StoreConfig = {
      name: STORE_NAME,
      securityLevel: relationalStore.SecurityLevel.S1,
    }
    const store: relationalStore.RdbStore = await relationalStore.getRdbStore(context, config)
    for (const ddl of CREATE_STATEMENTS) {
      await store.executeSql(ddl)
    }
    for (const ddl of INDEX_STATEMENTS) {
      await store.executeSql(ddl)
    }
    DataImportService.store = store
    return store
  }

  /** 确保数据已导入（幂等，并发安全） */
  static ensureImported(context: common.Context): Promise<ImportReport> {
    if (DataImportService.importing === undefined) {
      DataImportService.importing = DataImportService.doImport(context)
    }
    return DataImportService.importing
  }

  private static async readRawText(context: common.Context, path: string): Promise<string> {
    const bytes: Uint8Array = await context.resourceManager.getRawFileContent(path)
    const decoder: util.TextDecoder = util.TextDecoder.create('utf-8')
    return decoder.decodeToString(bytes)
  }

  private static async readMeta(context: common.Context): Promise<PresetMeta> {
    const text: string = await DataImportService.readRawText(context, `${RAW_DIR}/meta.json`)
    return JSON.parse(text) as PresetMeta
  }

  private static async readStoredVersion(store: relationalStore.RdbStore): Promise<string> {
    const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(Tables.META)
    predicates.equalTo('key', MetaKeys.DATA_VERSION)
    const rs: relationalStore.ResultSet = await store.query(predicates, ['value'])
    let version: string = ''
    if (rs.goToNextRow()) {
      version = rs.getString(rs.getColumnIndex('value'))
    }
    rs.close()
    return version
  }

  private static async putMeta(
    store: relationalStore.RdbStore,
    key: string,
    value: string
  ): Promise<void> {
    await store.executeSql(
      `INSERT OR REPLACE INTO ${Tables.META} (key, value) VALUES (?, ?)`,
      [key, value]
    )
  }

  private static async doImport(context: common.Context): Promise<ImportReport> {
    const started: number = Date.now()
    const store: relationalStore.RdbStore = await DataImportService.open(context)
    const meta: PresetMeta = await DataImportService.readMeta(context)

    const stored: string = await DataImportService.readStoredVersion(store)
    if (stored === meta.dataVersion) {
      return {
        skipped: true,
        dataVersion: meta.dataVersion,
        itemCount: meta.itemCount,
        chunkCount: meta.chunkCount,
        elapsedMs: Date.now() - started,
      }
    }

    // 全量重建：先清空业务表，再按事务写入
    for (const sql of TRUNCATE_STATEMENTS) {
      await store.executeSql(sql)
    }

    store.beginTransaction()
    try {
      await DataImportService.importItems(context, store)
      await DataImportService.importChunks(context, store)
      await DataImportService.importGraph(context, store)
      await DataImportService.importSimilar(context, store)
      store.commit()
    } catch (err) {
      store.rollBack()
      throw err as Error
    }

    await DataImportService.putMeta(store, MetaKeys.DATA_VERSION, meta.dataVersion)
    await DataImportService.putMeta(store, MetaKeys.CONTENT_HASH, meta.contentHash)
    await DataImportService.putMeta(store, MetaKeys.IMPORTED_AT, `${Date.now()}`)
    await DataImportService.putMeta(store, MetaKeys.ITEM_COUNT, `${meta.itemCount}`)

    return {
      skipped: false,
      dataVersion: meta.dataVersion,
      itemCount: meta.itemCount,
      chunkCount: meta.chunkCount,
      elapsedMs: Date.now() - started,
    }
  }

  private static async importItems(
    context: common.Context,
    store: relationalStore.RdbStore
  ): Promise<void> {
    const text: string = await DataImportService.readRawText(context, `${RAW_DIR}/items.json`)
    const items: HeritageItem[] = JSON.parse(text) as HeritageItem[]

    const rows: relationalStore.ValuesBucket[] = []
    for (const item of items) {
      const range: number[] | undefined =
        item.eraRange !== undefined ? [item.eraRange[0], item.eraRange[1]] : undefined
      rows.push({
        id: item.id,
        name: item.name,
        city: item.city,
        era: item.era,
        era_min: range !== undefined ? range[0] : 0,
        era_max: range !== undefined ? range[1] : 0,
        types: JSON.stringify(item.types),
        level: item.level !== undefined ? item.level : '',
        lat: item.geo.lat,
        lng: item.geo.lng,
        summary: item.summary,
        cover: item.images.length > 0 ? item.images[0].url : '',
        payload: JSON.stringify(item),
      })
    }
    await store.batchInsert(Tables.ITEMS, rows)
  }

  private static async importChunks(
    context: common.Context,
    store: relationalStore.RdbStore
  ): Promise<void> {
    const text: string = await DataImportService.readRawText(context, `${RAW_DIR}/chunks.jsonl`)
    const lines: string[] = text.split('\n')
    const rows: relationalStore.ValuesBucket[] = []
    for (const line of lines) {
      const trimmed: string = line.trim()
      if (trimmed.length === 0) {
        continue
      }
      const chunk: Chunk = JSON.parse(trimmed) as Chunk
      rows.push({
        id: chunk.id,
        item_id: chunk.itemId,
        section: chunk.section,
        seq: chunk.seq,
        text: chunk.text,
        tokens: chunk.tokens.join(' '),
      })
    }
    await store.batchInsert(Tables.CHUNKS, rows)
  }

  private static async importGraph(
    context: common.Context,
    store: relationalStore.RdbStore
  ): Promise<void> {
    const text: string = await DataImportService.readRawText(context, `${RAW_DIR}/graph.json`)
    const graph: GraphPayload = JSON.parse(text) as GraphPayload

    const nodeRows: relationalStore.ValuesBucket[] = []
    for (const node of graph.nodes) {
      nodeRows.push({
        id: node.id,
        type: node.type,
        name: node.name,
        aliases: node.aliases.join(' '),
        rank: node.rank !== undefined ? node.rank : 0,
      })
    }
    await store.batchInsert(Tables.GRAPH_NODES, nodeRows)

    const edgeRows: relationalStore.ValuesBucket[] = []
    for (const edge of graph.edges) {
      edgeRows.push({
        id: edge.id,
        src: edge.from,
        dst: edge.to,
        rel: edge.rel,
        weight: edge.weight,
        evidence: edge.evidence !== undefined ? edge.evidence : '',
      })
    }
    await store.batchInsert(Tables.GRAPH_EDGES, edgeRows)
  }

  private static async importSimilar(
    context: common.Context,
    store: relationalStore.RdbStore
  ): Promise<void> {
    const text: string = await DataImportService.readRawText(context, `${RAW_DIR}/similar.json`)
    const payload: SimilarPayload = JSON.parse(text) as SimilarPayload

    const rows: relationalStore.ValuesBucket[] = []
    for (const entry of payload.entries) {
      rows.push({
        item_id: entry.itemId,
        neighbors: JSON.stringify(entry.neighbors),
      })
    }
    await store.batchInsert(Tables.SIMILAR, rows)
  }
}

/** graph.json 的结构（与 @yra/shared 的 PresetGraph 对应） */
interface GraphPayload {
  readonly nodes: GraphNodePayload[]
  readonly edges: GraphEdgePayload[]
}

interface GraphNodePayload {
  readonly id: string
  readonly type: string
  readonly name: string
  readonly aliases: string[]
  readonly rank?: number
}

interface GraphEdgePayload {
  readonly id: string
  readonly from: string
  readonly to: string
  readonly rel: string
  readonly weight: number
  readonly evidence?: string
}

interface SimilarPayload {
  readonly entries: SimilarEntry[]
}
