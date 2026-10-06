/**
 * 语义检索通道。
 *
 * 关键在于**查询向量必须与建索引时的向量同一模型、同一维度、同一归一化方式**。
 * 实测百炼 text-embedding-v4 @1024 维的输出已是 L2 归一化（范数 1.0000），
 * 因此点积即余弦。这里再归一化一次（幂等），避免将来换模型时静默出错。
 *
 * 查询嵌入带 LRU 缓存：路演时同一句问题会被反复问，缓存能省下真实费用，
 * 也把二次查询的延迟从数百毫秒降到 0。
 */

import type { EmbeddingProvider } from '@yra/ai'

import type { Db } from '../db/index'
import { recordUsage } from './usage'
import type { VectorStore } from './vectors'

const DEFAULT_CACHE_SIZE: number = 256

/** 简易 LRU：Map 的插入顺序即访问顺序，超限就删最早的键 */
class LruCache<V> {
  private readonly map: Map<string, V> = new Map<string, V>()

  constructor(private readonly capacity: number) {}

  get(key: string): V | undefined {
    const value: V | undefined = this.map.get(key)
    if (value === undefined) {
      return undefined
    }
    // 重新插入以更新访问序
    this.map.delete(key)
    this.map.set(key, value)
    return value
  }

  set(key: string, value: V): void {
    if (this.map.has(key)) {
      this.map.delete(key)
    }
    this.map.set(key, value)
    if (this.map.size > this.capacity) {
      const oldest: string | undefined = this.map.keys().next().value
      if (oldest !== undefined) {
        this.map.delete(oldest)
      }
    }
  }

  get size(): number {
    return this.map.size
  }
}

/** 读 provider 的累计 token（provider 不暴露时为 0） */
function providerTokens(provider: unknown): number {
  const usage = (provider as { usage?: { tokens: number } }).usage
  return usage === undefined ? 0 : usage.tokens
}

/** 把向量归一化到单位长度（已归一化的输入不受影响） */
function normalize(vector: readonly number[]): Float32Array {
  const out = new Float32Array(vector.length)
  let norm: number = 0
  for (let i = 0; i < vector.length; i += 1) {
    const v: number = vector[i] ?? 0
    out[i] = v
    norm += v * v
  }
  norm = Math.sqrt(norm)
  if (norm === 0) {
    return out
  }
  for (let i = 0; i < out.length; i += 1) {
    out[i] = (out[i] ?? 0) / norm
  }
  return out
}

export interface VectorChannelOptions {
  readonly provider: EmbeddingProvider
  readonly store: VectorStore
  /** 传了就记账（缓存命中记 0 token，仍计入调用次数） */
  readonly db?: Db
  readonly cacheSize?: number
}

export interface VectorSearchResult {
  readonly ok: boolean
  readonly ranked: { chunkId: string; score: number }[]
  readonly error?: string
  /** 本次是否命中缓存（可用于统计与演示） */
  readonly cached: boolean
  readonly elapsedMs: number
}

export class VectorChannel {
  private readonly provider: EmbeddingProvider
  private readonly store: VectorStore
  private readonly db: Db | undefined
  private readonly cache: LruCache<Float32Array>

  constructor(options: VectorChannelOptions) {
    this.provider = options.provider
    this.store = options.store
    this.db = options.db
    this.cache = new LruCache<Float32Array>(options.cacheSize ?? DEFAULT_CACHE_SIZE)
  }

  get cacheSize(): number {
    return this.cache.size
  }

  /**
   * 检索。**不抛异常** —— 语义通道是增强项，它失败时应该降级到关键词通道，
   * 而不是让整个搜索请求失败（四级降级链的第一级，见设计文档 6.2）。
   */
  async search(query: string, topK: number, allow?: ReadonlySet<string>): Promise<VectorSearchResult> {
    const started: number = Date.now()
    const key: string = query.trim()

    let vector: Float32Array | undefined = this.cache.get(key)
    const cached: boolean = vector !== undefined

    if (vector === undefined) {
      const tokensBefore: number = providerTokens(this.provider)
      try {
        const vectors: number[][] = await this.provider.embed([key])
        const first: number[] | undefined = vectors[0]
        if (first === undefined) {
          this.log('embed_query', 0, started, false)
          return { ok: false, ranked: [], error: '嵌入服务返回空结果', cached: false, elapsedMs: Date.now() - started }
        }
        if (first.length !== this.store.dimension) {
          this.log('embed_query', 0, started, false)
          return {
            ok: false,
            ranked: [],
            error: `向量维度不匹配：查询 ${first.length}，索引 ${this.store.dimension}（模型或索引需重建）`,
            cached: false,
            elapsedMs: Date.now() - started,
          }
        }
        vector = normalize(first)
        this.cache.set(key, vector)
        this.log('embed_query', providerTokens(this.provider) - tokensBefore, started, true)
      } catch (err) {
        this.log('embed_query', providerTokens(this.provider) - tokensBefore, started, false)
        return {
          ok: false,
          ranked: [],
          error: err instanceof Error ? err.message.slice(0, 160) : String(err),
          cached: false,
          elapsedMs: Date.now() - started,
        }
      }
    } else {
      // 缓存命中：零 token，但仍计一次调用，否则统计看不出「省了多少次」
      this.log('embed_query_cached', 0, started, true)
    }

    const hits = this.store.search(vector, topK, allow)
    return { ok: true, ranked: hits, cached, elapsedMs: Date.now() - started }
  }

  private log(operation: string, tokens: number, startedAt: number, ok: boolean): void {
    if (this.db !== undefined) {
      recordUsage(this.db, operation, tokens, Date.now() - startedAt, ok)
    }
  }
}
