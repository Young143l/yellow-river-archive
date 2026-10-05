/**
 * 生成 provider（DeepSeek）。
 *
 * 两个用途，共用同一个 provider：
 *   1. 数据流水线的内容起草（构建期，一次性）
 *   2. 服务端的问答生成（运行期，流式）
 *
 * 接口按 provider 抽象，换厂商只改 baseUrl 与 model。
 */

import type { AiEnv } from './env'

export interface ChatMessage {
  readonly role: 'system' | 'user' | 'assistant'
  readonly content: string
}

export interface ChatOptions {
  /** 采样温度，起草用 0.3，问答用 0.2 */
  readonly temperature?: number
  readonly maxTokens?: number
  readonly timeoutMs?: number
  /** 要求模型输出严格 JSON（DeepSeek 支持 response_format） */
  readonly jsonMode?: boolean
}

export interface LlmProvider {
  readonly model: string
  /** 一次性返回完整回答 */
  complete(messages: readonly ChatMessage[], options?: ChatOptions): Promise<string>
  /** 流式返回，逐段产出文本增量 */
  stream(
    messages: readonly ChatMessage[],
    options?: ChatOptions
  ): Promise<AsyncIterable<string>>
}

interface ChatCompletionResponse {
  readonly choices?: { readonly message?: { readonly content?: string } }[]
  readonly usage?: { readonly total_tokens?: number }
  readonly error?: { readonly message?: string }
}

export class DeepSeekLlm implements LlmProvider {
  readonly model: string

  private readonly apiKey: string
  private readonly endpoint: string
  private totalTokens: number = 0
  private callCount: number = 0

  constructor(env: AiEnv, model?: string) {
    this.apiKey = env.deepseekKey
    this.model = model ?? env.deepseekModel
    this.endpoint = `${env.deepseekBaseUrl}/chat/completions`
  }

  get usage(): { readonly calls: number; readonly tokens: number } {
    return { calls: this.callCount, tokens: this.totalTokens }
  }

  /** 供流式解析回写用量（DeepSeek 在最后一帧才给 usage） */
  addTokens(n: number): void {
    this.totalTokens += n
  }

  private headers(): Record<string, string> {
    return {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${this.apiKey}`,
    }
  }

  async complete(messages: readonly ChatMessage[], options?: ChatOptions): Promise<string> {
    const body: Record<string, unknown> = {
      model: this.model,
      messages,
      temperature: options?.temperature ?? 0.3,
      max_tokens: options?.maxTokens ?? 4096,
      stream: false,
    }
    if (options?.jsonMode === true) {
      body.response_format = { type: 'json_object' }
    }

    const response: Response = await fetch(this.endpoint, {
      method: 'POST',
      headers: this.headers(),
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(options?.timeoutMs ?? 120_000),
    })

    if (!response.ok) {
      const text: string = await response.text()
      throw new Error(`生成请求失败 HTTP ${response.status}：${text.slice(0, 300)}`)
    }

    const parsed = (await response.json()) as ChatCompletionResponse
    if (parsed.error !== undefined) {
      throw new Error(`生成接口返回错误：${parsed.error.message ?? '未知'}`)
    }

    this.callCount += 1
    this.totalTokens += parsed.usage?.total_tokens ?? 0

    const content: string | undefined = parsed.choices?.[0]?.message?.content
    if (content === undefined) {
      throw new Error(`生成响应缺少内容：${JSON.stringify(parsed).slice(0, 300)}`)
    }
    return content
  }

  async stream(
    messages: readonly ChatMessage[],
    options?: ChatOptions
  ): Promise<AsyncIterable<string>> {
    const body = {
      model: this.model,
      messages,
      temperature: options?.temperature ?? 0.2,
      max_tokens: options?.maxTokens ?? 2048,
      stream: true,
    }
    const response: Response = await fetch(this.endpoint, {
      method: 'POST',
      headers: this.headers(),
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(options?.timeoutMs ?? 120_000),
    })

    if (!response.ok || response.body === null) {
      const text: string = await response.text()
      throw new Error(`流式生成请求失败 HTTP ${response.status}：${text.slice(0, 300)}`)
    }

    this.callCount += 1
    const bodyStream: ReadableStream<Uint8Array> = response.body
    return streamSse(bodyStream, this)
  }
}

/** 解析 SSE 流，产出文本增量 */
async function* streamSse(
  bodyStream: ReadableStream<Uint8Array>,
  provider: DeepSeekLlm
): AsyncGenerator<string> {
  const reader = bodyStream.getReader()
  const decoder = new TextDecoder('utf-8')
  let buffer: string = ''

  try {
    for (;;) {
      const { done, value } = await reader.read()
      if (done) {
        break
      }
      buffer += decoder.decode(value, { stream: true })
      let newlineAt: number = buffer.indexOf('\n')
      while (newlineAt >= 0) {
        const line: string = buffer.slice(0, newlineAt).trim()
        buffer = buffer.slice(newlineAt + 1)
        newlineAt = buffer.indexOf('\n')

        if (!line.startsWith('data:')) {
          continue
        }
        const payload: string = line.slice(5).trim()
        if (payload === '[DONE]') {
          return
        }
        try {
          const parsed = JSON.parse(payload) as {
            choices?: { delta?: { content?: string } }[]
            usage?: { total_tokens?: number }
          }
          const delta: string | undefined = parsed.choices?.[0]?.delta?.content
          if (delta !== undefined && delta.length > 0) {
            yield delta
          }
          if (parsed.usage?.total_tokens !== undefined) {
            provider.addTokens(parsed.usage.total_tokens)
          }
        } catch {
          // 忽略无法解析的心跳行
        }
      }
    }
  } finally {
    reader.releaseLock()
  }
}
