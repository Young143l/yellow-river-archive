/**
 * 外部调用的用量记账。
 *
 * provider 只暴露累计 token，不暴露单次用量，所以这里用「调用前后取差值」的
 * 方式记账。这样不用改动 provider 接口，也能把每次请求的成本落到表里。
 */

import type { RerankProvider, EmbeddingProvider } from '@yra/ai'

import { logUsage, type Db } from '../db/index'

/** 支持 tokens 计数的 provider（可选，缺失时按 0 记） */
interface UsageAware {
  readonly usage?: { readonly tokens: number }
}

function readTokens(provider: unknown): number | undefined {
  const usage = (provider as UsageAware).usage
  return usage === undefined ? undefined : usage.tokens
}

/**
 * 包一次外部调用，自动记录 tokens / 耗时 / 成败。
 *
 * **不改变原调用的异常行为** —— 记账是旁路，不该吞掉或改变业务异常。
 */
export async function withUsage<T>(
  db: Db,
  operation: string,
  provider: unknown,
  run: () => Promise<T>
): Promise<T> {
  if (operation.length === 0) {
    throw new Error('withUsage 需要非空的 operation 名')
  }
  const before: number | undefined = readTokens(provider)
  const started: number = Date.now()
  try {
    const result: T = await run()
    const after: number | undefined = readTokens(provider)
    const tokens: number = before !== undefined && after !== undefined ? after - before : 0
    logUsage(db, operation, tokens, Date.now() - started, true)
    return result
  } catch (err) {
    const after: number | undefined = readTokens(provider)
    const tokens: number = before !== undefined && after !== undefined ? after - before : 0
    logUsage(db, operation, tokens, Date.now() - started, false)
    throw err
  }
}

/** 手动记一笔（用于没有 provider 可测的场合，如缓存命中） */
export function recordUsage(
  db: Db,
  operation: string,
  tokens: number,
  elapsedMs: number,
  ok: boolean
): void {
  logUsage(db, operation, tokens, elapsedMs, ok)
}

/** 便捷：让 embedding provider 参与记账 */
export type UsageTrackedEmbedding = EmbeddingProvider & UsageAware
export type UsageTrackedRerank = RerankProvider & UsageAware
