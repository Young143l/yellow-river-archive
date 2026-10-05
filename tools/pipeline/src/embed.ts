/**
 * 嵌入流水线。
 *
 * 产物：packages/data/derived/embeddings/{vectors.f32, index.json}
 *   - vectors.f32：所有向量按顺序拼接的 Float32 二进制
 *   - index.json：每个 chunk 在二进制中的偏移与校验信息
 *
 * 三条工程约束（都来自实战，不是洁癖）：
 *   1. **按内容哈希缓存** —— 重建索引时只对新片段计费（缓存落 .cache/，已 gitignore）
 *   2. **批量切分** —— 实测单次上限 10 条，超了直接被拒
 *   3. **退避重试 + 断点续跑** —— 中途失败不必从头再来
 *
 * 嵌入文本的选择：`${条目名}｜${片段正文}`。
 * 为什么不直接用正文：不少片段通篇不提自己的遗址名（如"遗址面积约三百万平方米……"），
 * 单独编码这类片段会丢失主语，召回质量明显下降。加上条目前缀是 RAG 的常规做法，
 * 且**不影响展示与引用** —— 引用卡片用的仍是片段原文。
 */

import { createHash } from 'node:crypto'
import { existsSync } from 'node:fs'
import { appendFile, mkdir, readFile, writeFile } from 'node:fs/promises'
import { dirname, join } from 'node:path'

import { DashScopeEmbedding, readEmbeddingEnv } from '@yra/ai'

import type { Chunk, HeritageItem } from '@yra/shared'

/** 缓存文件格式版本，格式变更时递增以作废旧缓存 */
const CACHE_VERSION: number = 1

interface CacheLine {
  readonly v: number
  readonly hash: string
  readonly model: string
  readonly dim: number
  readonly vector: number[]
}

export interface EmbeddingIndexEntry {
  readonly chunkId: string
  readonly itemId: string
  readonly hash: string
  /** 在 vectors.f32 中的起始下标（以 float 为单位，不是字节） */
  readonly offset: number
  readonly dim: number
}

export interface EmbeddingIndex {
  readonly version: number
  readonly model: string
  readonly dim: number
  readonly count: number
  readonly generatedAt: string
  readonly entries: readonly EmbeddingIndexEntry[]
}

export interface EmbedOptions {
  readonly items: readonly HeritageItem[]
  readonly chunks: readonly Chunk[]
  readonly cacheFile: string
  readonly outDir: string
  /** 每批之间的间隔，避免触发限流 */
  readonly gapMs?: number
  /** 单次运行最多处理多少条（用于分段试跑），缺省不限 */
  readonly limit?: number
}

export interface EmbedReport {
  readonly total: number
  readonly cached: number
  readonly embedded: number
  readonly failed: number
  readonly elapsedMs: number
  readonly tokens: number
  readonly model: string
  readonly dim: number
}

/** 缓存键：模型 + 维度 + 嵌入文本，任一变化都要重新编码 */
function cacheKey(model: string, dim: number, text: string): string {
  return createHash('sha256').update(`${model}|${dim}|${text}`).digest('hex')
}

async function readCache(cacheFile: string): Promise<Map<string, number[]>> {
  const map: Map<string, number[]> = new Map<string, number[]>()
  if (!existsSync(cacheFile)) {
    return map
  }
  const raw: string = await readFile(cacheFile, 'utf8')
  for (const line of raw.split('\n')) {
    const trimmed: string = line.trim()
    if (trimmed.length === 0) {
      continue
    }
    try {
      const parsed = JSON.parse(trimmed) as CacheLine
      if (parsed.v === CACHE_VERSION) {
        map.set(parsed.hash, parsed.vector)
      }
    } catch {
      // 忽略损坏的缓存行
    }
  }
  return map
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, ms)
  })
}

export async function runEmbedding(options: EmbedOptions): Promise<EmbedReport> {
  const started: number = Date.now()
  const env = readEmbeddingEnv()
  const provider = new DashScopeEmbedding(env)

  await mkdir(dirname(options.cacheFile), { recursive: true })
  await mkdir(options.outDir, { recursive: true })

  const cache: Map<string, number[]> = await readCache(options.cacheFile)
  const nameById: Map<string, string> = new Map<string, string>()
  for (const item of options.items) {
    nameById.set(item.id, item.name)
  }

  // 组装待编码文本并计算缓存键
  interface Pending {
    readonly chunk: Chunk
    readonly text: string
    readonly hash: string
  }
  const all: Pending[] = []
  const hashOf: Map<string, string> = new Map<string, string>()
  for (const chunk of options.chunks) {
    const name: string = nameById.get(chunk.itemId) ?? chunk.itemId
    const text: string = `${name}｜${chunk.text}`
    const hash: string = cacheKey(provider.model, provider.dim, text)
    hashOf.set(chunk.id, hash)
    all.push({ chunk, text, hash })
  }

  const missing: Pending[] = all.filter((p) => !cache.has(p.hash))
  const limited: Pending[] =
    options.limit !== undefined ? missing.slice(0, options.limit) : missing

  console.log(
    `[embed] 模型 ${provider.model} @ ${provider.dim} 维 ｜ 片段 ${all.length} 个 ｜ 命中缓存 ${all.length - missing.length} 个 ｜ 本次待编码 ${limited.length} 个`
  )

  const gapMs: number = options.gapMs ?? 120
  let embedded: number = 0
  let failed: number = 0
  const newlyGenerated: { hash: string; vector: number[] }[] = []

  for (let i = 0; i < limited.length; i += provider.batchSize) {
    const batch: Pending[] = limited.slice(i, i + provider.batchSize)
    const texts: string[] = batch.map((b) => b.text)

    let attempt: number = 0
    let ok: boolean = false
    while (!ok && attempt < 3) {
      attempt += 1
      try {
        const vectors: number[][] = await provider.embed(texts)
        for (let k = 0; k < batch.length; k++) {
          const vector: number[] | undefined = vectors[k]
          if (vector === undefined) {
            throw new Error(`第 ${k} 条缺少向量`)
          }
          cache.set(batch[k]!.hash, vector)
          newlyGenerated.push({ hash: batch[k]!.hash, vector })
        }
        embedded += batch.length
        ok = true
      } catch (err) {
        const message: string = err instanceof Error ? err.message : String(err)
        if (attempt >= 3) {
          console.error(`[embed] 批次失败（已重试 ${attempt} 次）：${message.slice(0, 160)}`)
          failed += batch.length
        } else {
          const backoff: number = 1000 * 2 ** (attempt - 1)
          console.warn(`[embed] 批次失败，${backoff}ms 后重试（第 ${attempt} 次）：${message.slice(0, 120)}`)
          await sleep(backoff)
        }
      }
    }

    // 增量落缓存：即使中途中断，已完成的批次不会白跑
    if (newlyGenerated.length > 0) {
      const lines: string = newlyGenerated
        .map((n) => JSON.stringify({ v: CACHE_VERSION, hash: n.hash, model: provider.model, dim: provider.dim, vector: n.vector }))
        .join('\n')
      await appendFile(options.cacheFile, `${lines}\n`, 'utf8')
      newlyGenerated.length = 0
    }

    if (limited.length > 40 && i % 200 === 0) {
      console.log(`[embed] 进度 ${Math.min(i + provider.batchSize, limited.length)} / ${limited.length}`)
    }
    if (i + provider.batchSize < limited.length) {
      await sleep(gapMs)
    }
  }

  // 组装二进制与索引
  const entries: EmbeddingIndexEntry[] = []
  const vectors: number[] = []
  let offset: number = 0
  for (const p of all) {
    const vector: number[] | undefined = cache.get(p.hash)
    if (vector === undefined) {
      // 本次未覆盖到的片段（受 limit 限制或失败），跳过；下次运行会补上
      continue
    }
    entries.push({
      chunkId: p.chunk.id,
      itemId: p.chunk.itemId,
      hash: p.hash,
      offset,
      dim: vector.length,
    })
    for (const value of vector) {
      vectors.push(value)
    }
    offset += vector.length
  }

  const binary: Float32Array = Float32Array.from(vectors)
  await writeFile(join(options.outDir, 'vectors.f32'), Buffer.from(binary.buffer))

  const index: EmbeddingIndex = {
    version: CACHE_VERSION,
    model: provider.model,
    dim: provider.dim,
    count: entries.length,
    generatedAt: new Date().toISOString(),
    entries,
  }
  await writeFile(join(options.outDir, 'index.json'), JSON.stringify(index, null, 2), 'utf8')

  return {
    total: all.length,
    cached: all.length - missing.length,
    embedded,
    failed,
    elapsedMs: Date.now() - started,
    tokens: provider.usage.tokens,
    model: provider.model,
    dim: provider.dim,
  }
}
