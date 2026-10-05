/**
 * 环境变量读取与校验。
 *
 * 为什么读文件而不是硬编码：密钥不进仓库（见全局规则）。`.env` 已在 .gitignore 中，
 * 模板见 docs/env-template.md。
 *
 * 为什么放在仓库根目录：数据流水线（构建期）与服务端（运行期）用同一批 Key，
 * 放一处避免两套配置不同步。
 */

import { existsSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE: string = dirname(fileURLToPath(import.meta.url))
const REPO_ROOT: string = resolve(HERE, '..', '..', '..')

/** 从仓库根目录的 .env 载入（若存在）。已存在的 process.env 优先，不被覆盖。 */
export function loadEnv(): void {
  const envPath: string = join(REPO_ROOT, '.env')
  if (!existsSync(envPath)) {
    return
  }
  // Node 20.12+ 提供 process.loadEnvFile
  process.loadEnvFile(envPath)
}

export interface AiEnv {
  readonly dashscopeKey: string
  readonly dashscopeBaseUrl: string
  readonly embeddingModel: string
  readonly embeddingDim: number
  readonly rerankModel: string
  readonly deepseekKey: string
  readonly deepseekBaseUrl: string
  readonly deepseekModel: string
}

function require_(name: string): string {
  const value: string | undefined = process.env[name]
  if (value === undefined || value.length === 0) {
    throw new Error(
      `缺少环境变量 ${name}。请在仓库根目录创建 .env（模板见 docs/env-template.md），` +
        `或直接以环境变量方式传入。`
    )
  }
  return value
}

function optional(name: string, fallback: string): string {
  const value: string | undefined = process.env[name]
  return value !== undefined && value.length > 0 ? value : fallback
}

export function readEnv(): AiEnv {
  loadEnv()
  return {
    dashscopeKey: require_('DASHSCOPE_API_KEY'),
    dashscopeBaseUrl: optional('DASHSCOPE_BASE_URL', 'https://dashscope.aliyuncs.com'),
    embeddingModel: optional('EMBEDDING_MODEL', 'text-embedding-v4'),
    embeddingDim: Number.parseInt(optional('EMBEDDING_DIM', '1024'), 10),
    rerankModel: optional('RERANK_MODEL', 'gte-rerank-v2'),
    deepseekKey: require_('DEEPSEEK_API_KEY'),
    deepseekBaseUrl: optional('DEEPSEEK_BASE_URL', 'https://api.deepseek.com'),
    deepseekModel: optional('DEEPSEEK_MODEL', 'deepseek-chat'),
  }
}

/** 只读取嵌入相关配置，供流水线在不需要生成能力时使用 */
export interface EmbeddingEnv {
  readonly dashscopeKey: string
  readonly dashscopeBaseUrl: string
  readonly embeddingModel: string
  readonly embeddingDim: number
  readonly rerankModel: string
}

export function readEmbeddingEnv(): EmbeddingEnv {
  loadEnv()
  return {
    dashscopeKey: require_('DASHSCOPE_API_KEY'),
    dashscopeBaseUrl: optional('DASHSCOPE_BASE_URL', 'https://dashscope.aliyuncs.com'),
    embeddingModel: optional('EMBEDDING_MODEL', 'text-embedding-v4'),
    embeddingDim: Number.parseInt(optional('EMBEDDING_DIM', '1024'), 10),
    rerankModel: optional('RERANK_MODEL', 'gte-rerank-v2'),
  }
}
