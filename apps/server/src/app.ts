import { readFileSync } from 'node:fs'
import { join } from 'node:path'

import {
  DashScopeEmbedding,
  DashScopeRerank,
  readEmbeddingEnv,
  type EmbeddingProvider,
  type RerankProvider,
} from '@yra/ai'
import { Tokenizer } from '@yra/nlp'
import type { VocabEntry } from '@yra/shared'
import Fastify, { type FastifyInstance } from 'fastify'

import { readServerConfig, type ServerConfig } from './config'
import { getMeta, openDb } from './db/index'
import { importPreset } from './db/import'
import { MetaKeys } from './db/schema'
import { buildEntityDictionary, describeDictionary } from './search/query-understanding'
import { itemsRoutes } from './routes/items'
import { searchRoutes } from './routes/search'
import { statsRoutes } from './routes/stats'
import { createVectorChannel } from './search/service'
import { VectorStore } from './search/vectors'

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

  // ---- 向量库（启动时全部载入内存，暴力检索，见 ADR-005）----
  const vectors: VectorStore = VectorStore.load(db)
  app.log.info(`向量库就绪：${vectors.size} 条 / ${vectors.dimension} 维`)

  // ---- 分词器 ----
  // 用预置包的 vocab.json 当词典：它与建索引时的分词同源，
  // 保证「索引里有的词，查询也能切出来」。服务端不读 lexicon.txt，
  // 避免两份词典不同步导致 BM25 静默失效。
  const vocabPath: string = join(config.presetDir, 'vocab.json')
  const vocabFile = JSON.parse(readFileSync(vocabPath, 'utf8')) as { entries: VocabEntry[] }
  const tokenizer: Tokenizer = Tokenizer.createFromVocab(vocabFile.entries)
  app.log.info(`分词器就绪：${vocabFile.entries.length} 个领域词`)

  // ---- 语义通道与精排 ----
  const embedding: EmbeddingProvider = new DashScopeEmbedding(readEmbeddingEnv())
  const vectorChannel = createVectorChannel(embedding, vectors, db)
  const rerankProvider: RerankProvider = new DashScopeRerank(readEmbeddingEnv())
  app.log.info(`语义通道就绪：${embedding.model} @ ${embedding.dim} 维`)
  app.log.info(`精排就绪：${rerankProvider.model}`)

  // ---- 实体词典（查询理解用）----
  const dict = buildEntityDictionary(db)
  app.log.info(`实体词典就绪：${describeDictionary(dict)}`)

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
      vectorCount: vectors.size,
      vocabSize: vocabFile.entries.length,
      entityTerms: dict.terms.size,
    }
  })

  // ---- 业务路由 ----
  await app.register(itemsRoutes, { db, vectors })
  await app.register(searchRoutes, { db, vectors, tokenizer, dict, vectorChannel, rerankProvider })
  await app.register(statsRoutes, { db })

  return app
}
