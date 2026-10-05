/**
 * 重排 provider（阿里云百炼）。
 *
 * 作用：在 RRF 融合之后对候选做一次精排，显著提升最终命中质量。
 * 走百炼原生端点（rerank 不在 OpenAI 兼容协议里）。
 */

import type { EmbeddingEnv } from './env'

export interface RerankHit {
  /** 原始候选下标 */
  readonly index: number
  readonly score: number
}

export interface RerankProvider {
  readonly model: string
  rerank(query: string, documents: readonly string[], topN: number): Promise<RerankHit[]>
}

interface RerankResponse {
  readonly output?: { readonly results?: { readonly index: number; readonly relevance_score: number }[] }
  readonly usage?: { readonly total_tokens?: number }
  readonly code?: string
  readonly message?: string
}

export class DashScopeRerank implements RerankProvider {
  readonly model: string

  private readonly apiKey: string
  private readonly endpoint: string
  private totalTokens: number = 0

  constructor(env: EmbeddingEnv) {
    this.apiKey = env.dashscopeKey
    this.model = env.rerankModel
    this.endpoint = `${env.dashscopeBaseUrl}/api/v1/services/rerank/text-rerank/text-rerank`
  }

  get usage(): { readonly tokens: number } {
    return { tokens: this.totalTokens }
  }

  async rerank(query: string, documents: readonly string[], topN: number): Promise<RerankHit[]> {
    if (documents.length === 0) {
      return []
    }

    const body = {
      model: this.model,
      input: {
        query,
        documents,
      },
      parameters: {
        top_n: Math.min(topN, documents.length),
        return_documents: false,
      },
    }

    const response: Response = await fetch(this.endpoint, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${this.apiKey}`,
      },
      body: JSON.stringify(body),
    })

    if (!response.ok) {
      const text: string = await response.text()
      throw new Error(`重排请求失败 HTTP ${response.status}：${text.slice(0, 300)}`)
    }

    const parsed = (await response.json()) as RerankResponse
    const results = parsed.output?.results
    if (results === undefined) {
      throw new Error(`重排响应异常：${JSON.stringify(parsed).slice(0, 300)}`)
    }

    this.totalTokens += parsed.usage?.total_tokens ?? 0

    return results.map((r) => ({ index: r.index, score: r.relevance_score }))
  }
}
