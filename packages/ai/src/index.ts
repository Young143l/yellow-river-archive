/**
 * @yra/ai —— AI 能力 provider 层
 *
 * 被两处引用：
 *   - tools/pipeline（构建期）：嵌入、重排、内容起草
 *   - apps/server（运行期）：检索重排、问答生成
 *
 * 选型与实测记录见 docs/决策日志.md（ADR-002 / ADR-003）与 docs/ai-providers.md。
 */

export { loadEnv, readEnv, readEmbeddingEnv } from './env'
export type { AiEnv, EmbeddingEnv } from './env'
export { DashScopeEmbedding } from './embedding'
export type { EmbeddingProvider } from './embedding'
export { DashScopeRerank } from './rerank'
export type { RerankHit, RerankProvider } from './rerank'
export { DeepSeekLlm } from './llm'
export type { ChatMessage, ChatOptions, LlmProvider } from './llm'
