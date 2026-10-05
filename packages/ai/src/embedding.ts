/**
 * 嵌入 provider（阿里云百炼）。
 *
 * 走 OpenAI 兼容端点，便于日后换厂商时只改 baseUrl 与 model。
 * 索引与查询必须使用**同一模型同一维度**，否则向量空间不一致、相似度无意义。
 */

import type { EmbeddingEnv } from './env'

export interface EmbeddingProvider {
  readonly model: string
  readonly dim: number
  /** 单次请求的文本条数上限（实测得出，见 docs/ai-providers.md） */
  readonly batchSize: number
  embed(texts: readonly string[]): Promise<number[][]>
}

interface EmbeddingResponseItem {
  readonly index: number
  readonly embedding: number[]
}

interface EmbeddingResponse {
  readonly data: EmbeddingResponseItem[]
  readonly usage?: { readonly total_tokens?: number }
  readonly code?: string
  readonly message?: string
}

export class DashScopeEmbedding implements EmbeddingProvider {
  readonly model: string
  readonly dim: number
  readonly batchSize: number

  private readonly apiKey: string
  private readonly endpoint: string

  /** 累计用量，供流水线统计成本 */
  private totalTokens: number = 0
  private callCount: number = 0

  constructor(env: EmbeddingEnv, batchSize: number = 10) {
    this.apiKey = env.dashscopeKey
    this.model = env.embeddingModel
    this.dim = env.embeddingDim
    this.batchSize = batchSize
    this.endpoint = `${env.dashscopeBaseUrl}/compatible-mode/v1/embeddings`
  }

  get usage(): { readonly calls: number; readonly tokens: number } {
    return { calls: this.callCount, tokens: this.totalTokens }
  }

  async embed(texts: readonly string[]): Promise<number[][]> {
    if (texts.length === 0) {
      return []
    }
    if (texts.length > this.batchSize) {
      throw new Error(`单次嵌入条数 ${texts.length} 超过上限 ${this.batchSize}`)
    }

    const body = {
      model: this.model,
      input: texts,
      dimensions: this.dim,
      encoding_format: 'float',
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
      throw new Error(`嵌入请求失败 HTTP ${response.status}：${text.slice(0, 300)}`)
    }

    const parsed = (await response.json()) as EmbeddingResponse
    if (parsed.data === undefined || parsed.data.length !== texts.length) {
      throw new Error(`嵌入响应异常：期望 ${texts.length} 条，实际 ${parsed.data?.length ?? 0} 条`)
    }

    this.callCount += 1
    this.totalTokens += parsed.usage?.total_tokens ?? 0

    // 服务端不保证顺序，按 index 归位
    const ordered: number[][] = new Array<number[]>(texts.length)
    for (const item of parsed.data) {
      ordered[item.index] = item.embedding
    }
    return ordered
  }
}
