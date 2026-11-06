import { readFileSync } from 'node:fs'
import { join } from 'node:path'

import {
  DashScopeEmbedding,
  DashScopeRerank,
  DashScopeLlm,
  DeepSeekLlm,
  readEmbeddingEnv,
  readEnv,
  type EmbeddingProvider,
  type LlmProvider,
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
import { graphRoutes } from './routes/graph'
import { registerAuthRoutes } from './routes/auth'
import { itemsRoutes } from './routes/items'
import { qaRoutes } from './routes/qa'
import { searchRoutes } from './routes/search'
import { statsRoutes } from './routes/stats'
import { syncRoutes } from './routes/sync'
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
  // 缺 Key 时仍然启动，语义通道与精排按请求降级（实测会落到纯 BM25）。
  // 这是 ADR-037 四级降级的服务端一半：进程不能因为少一个 Key 就起不来。
  const embedEnv = readEmbeddingEnv(true)
  const embedding: EmbeddingProvider = new DashScopeEmbedding(embedEnv)
  const vectorChannel = createVectorChannel(embedding, vectors, db)
  const rerankProvider: RerankProvider = new DashScopeRerank(embedEnv)
  if (embedEnv.dashscopeKey.length === 0) {
    app.log.warn('未配置 DASHSCOPE_API_KEY：语义通道与精排不可用，检索降级为纯 BM25')
  } else {
    app.log.info(`语义通道就绪：${embedding.model} @ ${embedding.dim} 维`)
    app.log.info(`精排就绪：${rerankProvider.model}`)
  }

  // ---- 生成模型（问答用）----
  // 两家都能用，按可用性选：DeepSeek 有时代金余额会变成负数（实测 -0.10 元），
  // 此时请求一律 402，问答就静默退化成检索摘要 —— 看起来像「AI 坏了」。
  // 所以有明显余额的百炼优先，DeepSeek 作为备选，可用 YRA_LLM 强制指定。
  const llmEnv = readEnv(true)
  const prefer: string = process.env.YRA_LLM ?? 'dashscope'
  const useDeepSeek: boolean =
    prefer === 'deepseek' && llmEnv.deepseekKey.length > 0
  const llm: LlmProvider = useDeepSeek
    ? new DeepSeekLlm(llmEnv)
    : new DashScopeLlm(llmEnv)
  if (llmEnv.dashscopeKey.length === 0 && llmEnv.deepseekKey.length === 0) {
    app.log.warn('两家生成 Key 都没配：问答生成不可用，/api/qa 只返回检索原文摘要')
  } else {
    app.log.info(`生成就绪：${llm.model}（provider=${useDeepSeek ? 'deepseek' : 'dashscope'}）`)
  }

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
  registerAuthRoutes(app, db)
  await app.register(searchRoutes, { db, vectors, tokenizer, dict, vectorChannel, rerankProvider })
  await app.register(graphRoutes, { db })
  await app.register(statsRoutes, { db })
  await app.register(syncRoutes, { db })
  await app.register(qaRoutes, {
    db,
    searchDeps: { db, vectors, tokenizer, dict, vectorChannel, rerankProvider },
    llm,
  })

  return app
}
