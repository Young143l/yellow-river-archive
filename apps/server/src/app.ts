import Fastify, { type FastifyInstance } from 'fastify'

import { readServerConfig, type ServerConfig } from './config'
import { getMeta, openDb } from './db/index'
import { importPreset } from './db/import'
import { MetaKeys } from './db/schema'

export interface BuildOptions {
  /** 覆盖配置（测试用） */
  readonly config?: ServerConfig
  /** 启动时是否导入数据 */
  readonly importData?: boolean
}

export async function buildServer(options: BuildOptions = {}): Promise<FastifyInstance> {
  const config: ServerConfig = options.config ?? readServerConfig()
  const app: FastifyInstance = Fastify({
    logger: { level: config.logLevel },
  })

  const db = openDb(config.dbPath)

  if (options.importData !== false) {
    const summary = importPreset(db, config.presetDir, `${config.repoRoot}/packages/data/derived/embeddings`)
    app.log.info(
      summary.skipped
        ? `数据已是最新（${summary.dataVersion}），跳过导入`
        : `数据导入完成：${summary.items} 条目 / ${summary.chunks} 片段 / ${summary.vectors} 向量 / ${summary.nodes} 节点 / ${summary.edges} 连边，耗时 ${summary.elapsedMs}ms`
    )
  }

  // ---- 健康检查 ----
  app.get('/api/health', async () => {
    return {
      ok: true,
      dataVersion: getMeta(db, MetaKeys.DATA_VERSION) ?? '',
      contentHash: getMeta(db, MetaKeys.CONTENT_HASH) ?? '',
      itemCount: Number.parseInt(getMeta(db, MetaKeys.ITEM_COUNT) ?? '0', 10),
      chunkCount: Number.parseInt(getMeta(db, MetaKeys.CHUNK_COUNT) ?? '0', 10),
      embeddingModel: getMeta(db, MetaKeys.EMBEDDING_MODEL) ?? '',
      embeddingDim: Number.parseInt(getMeta(db, MetaKeys.EMBEDDING_DIM) ?? '0', 10),
      uptimeMs: Math.round(process.uptime() * 1000),
    }
  })

  return app
}
