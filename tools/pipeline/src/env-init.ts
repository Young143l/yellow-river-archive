/**
 * 环境变量初始化。
 *
 * 用法：
 *   pnpm env:init -- --dashscope=<百炼Key> --deepseek=<DeepSeekKey>
 *
 * 为什么要这个脚本：多行 heredoc 在终端里粘贴容易出错（换行被吃掉、缩进混入），
 * 单行命令 + 参数解析更可靠。同时把变量集合固定在代码里，避免各处文档口径不一。
 *
 * 安全：写入的是仓库根目录的 .env，已在 .gitignore 中；pre-commit 钩子也会
 * 扫描 sk- 开头的疑似密钥并阻止提交。
 */

import { existsSync } from 'node:fs'
import { writeFile } from 'node:fs/promises'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE: string = dirname(fileURLToPath(import.meta.url))
const REPO_ROOT: string = resolve(HERE, '..', '..', '..')
const ENV_PATH: string = join(REPO_ROOT, '.env')

interface Args {
  readonly dashscope: string
  readonly deepseek: string
  readonly force: boolean
}

function parseArgs(argv: readonly string[]): Args {
  let dashscope: string = ''
  let deepseek: string = ''
  let force: boolean = false

  for (const arg of argv) {
    if (arg.startsWith('--dashscope=')) {
      dashscope = arg.slice('--dashscope='.length).trim()
    } else if (arg.startsWith('--deepseek=')) {
      deepseek = arg.slice('--deepseek='.length).trim()
    } else if (arg === '--force') {
      force = true
    }
  }
  return { dashscope, deepseek, force }
}

function fail(message: string): never {
  console.error(`[env:init] ${message}`)
  console.error('')
  console.error('  用法：pnpm env:init -- --dashscope=<百炼Key> --deepseek=<DeepSeekKey>')
  console.error('  已有 .env 时需加 --force 才会覆盖')
  process.exit(1)
}

function looksLikeKey(value: string, prefix: string): boolean {
  return value.startsWith(prefix) && value.length >= 20
}

async function main(): Promise<void> {
  const args: Args = parseArgs(process.argv.slice(2))

  if (args.dashscope.length === 0 || args.deepseek.length === 0) {
    fail('缺少参数')
  }
  if (!looksLikeKey(args.dashscope, 'sk-')) {
    fail('--dashscope 看起来不是有效的 Key（应以 sk- 开头且长度足够）')
  }
  if (!looksLikeKey(args.deepseek, 'sk-')) {
    fail('--deepseek 看起来不是有效的 Key（应以 sk- 开头且长度足够）')
  }

  if (existsSync(ENV_PATH) && !args.force) {
    fail('.env 已存在。确需覆盖请加 --force')
  }

  const content: string = [
    '# 本地密钥文件 —— 已在 .gitignore 中，不会入库',
    '# 由 pnpm env:init 生成；变量说明见 docs/env-template.md',
    '',
    '# ---- 阿里云百炼（嵌入与重排）----',
    `DASHSCOPE_API_KEY=${args.dashscope}`,
    'DASHSCOPE_BASE_URL=https://dashscope.aliyuncs.com',
    '',
    '# 嵌入模型与维度：实测记录见 docs/ai-providers.md',
    '# 维度一经确定不可随意改（需重建全部索引）',
    'EMBEDDING_MODEL=text-embedding-v4',
    'EMBEDDING_DIM=1024',
    'RERANK_MODEL=gte-rerank-v2',
    '',
    '# ---- DeepSeek（问答生成与内容起草）----',
    `DEEPSEEK_API_KEY=${args.deepseek}`,
    'DEEPSEEK_BASE_URL=https://api.deepseek.com',
    'DEEPSEEK_MODEL=deepseek-chat',
    '',
  ].join('\n')

  await writeFile(ENV_PATH, content, 'utf8')

  const mask = (v: string): string => `${v.slice(0, 6)}…${v.slice(-4)}`
  console.log('[env:init] 已写入 .env')
  console.log(`  路径          ${ENV_PATH}`)
  console.log(`  百炼 Key      ${mask(args.dashscope)}`)
  console.log(`  DeepSeek Key  ${mask(args.deepseek)}`)
  console.log('')
  console.log('  下一步：pnpm ai:check 验证连通性')
}

main().catch((err: unknown) => {
  console.error('[env:init] 失败：', err instanceof Error ? err.message : err)
  process.exit(1)
})
