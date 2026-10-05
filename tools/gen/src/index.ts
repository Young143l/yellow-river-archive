/**
 * ArkTS 类型生成器
 *
 * 把 packages/shared 中的"纯声明文件"（constants / models / preset / api）
 * 生成到端侧工程的 ets/shared 目录，保证两端类型永不漂移。
 *
 * 用法：
 *   pnpm gen:arkts                     生成到默认路径
 *   pnpm --filter @yra/gen run gen --out=<dir>   生成到指定目录（本地调试用）
 *   pnpm --filter @yra/gen run gen:check         只校验是否已同步（pre-push 用）
 *
 * 为什么不做 AST 转换：这四份文件本身就是纯类型与常量声明，不含逻辑，
 * 逐字复制即可，改成 AST 只会引入无谓的复杂度与出错面。
 */

import { mkdir, readFile, writeFile } from 'node:fs/promises'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = resolve(HERE, '..', '..', '..')

/** 参与生成源文件（顺序即依赖顺序） */
const SOURCE_FILES = ['constants', 'models', 'preset', 'api'] as const

const SRC_DIR = join(REPO_ROOT, 'packages', 'shared', 'src')
const DEFAULT_OUT_DIR = join(
  REPO_ROOT,
  'harmony',
  'YellowRiverArchive',
  'entry',
  'src',
  'main',
  'ets',
  'shared'
)

/** 生成物头部标记，用于判断文件是否由本工具产出 */
const GENERATED_MARK = '本文件由 tools/gen 自动生成'

function header(sourceName: string): string {
  return [
    '/**',
    ` * ${GENERATED_MARK}，请勿手改。`,
    ` * 源文件：packages/shared/src/${sourceName}.ts`,
    ' * 重新生成：pnpm gen:arkts',
    ' */',
    '',
  ].join('\n')
}

/** 逐字复制，仅做少量稳妥的规整 */
function transform(code: string): string {
  return (
    code
      // 去掉源文件自己的文件级注释块（由生成头替代）
      .replace(/^\/\*\*[\s\S]*?\*\/\s*/, '')
      // 连续空行压缩
      .replace(/\n{3,}/g, '\n\n')
      .trimEnd()
      .concat('\n')
  )
}

const BARREL = [
  '/*',
  ` * ${GENERATED_MARK}，请勿手改。`,
  ' * 统一出口：import { HeritageItem } from \'../shared\'',
  ' */',
  '',
  ...SOURCE_FILES.map((n) => `export * from './${n}'`),
  '',
].join('\n')

interface Options {
  readonly outDir: string
  readonly check: boolean
}

function parseArgs(argv: readonly string[]): Options {
  let outDir = DEFAULT_OUT_DIR
  let check = false
  for (const arg of argv) {
    if (arg === '--check') {
      check = true
    } else if (arg.startsWith('--out=')) {
      outDir = resolve(process.cwd(), arg.slice('--out='.length))
    }
  }
  return { outDir, check }
}

async function main(): Promise<void> {
  const { outDir, check } = parseArgs(process.argv.slice(2))

  const outputs: { name: string; content: string }[] = []
  for (const name of SOURCE_FILES) {
    const raw = await readFile(join(SRC_DIR, `${name}.ts`), 'utf8')
    outputs.push({ name: `${name}.ets`, content: header(name) + transform(raw) })
  }
  outputs.push({ name: 'index.ets', content: BARREL })

  if (check) {
    const stale: string[] = []
    for (const out of outputs) {
      const target = join(outDir, out.name)
      try {
        const existing = await readFile(target, 'utf8')
        if (existing !== out.content) stale.push(out.name)
      } catch {
        stale.push(`${out.name}（缺失）`)
      }
    }
    if (stale.length > 0) {
      console.error('[gen] 端侧类型未同步，请运行 pnpm gen:arkts')
      for (const s of stale) console.error(`  - ${s}`)
      process.exit(1)
    }
    console.log('[gen] 端侧类型已同步')
    return
  }

  await mkdir(outDir, { recursive: true })
  for (const out of outputs) {
    await writeFile(join(outDir, out.name), out.content, 'utf8')
  }

  const rel = outDir.startsWith(REPO_ROOT) ? outDir.slice(REPO_ROOT.length + 1) : outDir
  console.log(`[gen] 已生成 ${outputs.length} 个文件 -> ${rel}`)
  for (const out of outputs) {
    console.log(`      ${out.name}  (${out.content.split('\n').length} 行)`)
  }
}

main().catch((err: unknown) => {
  console.error('[gen] 失败：', err instanceof Error ? err.message : err)
  process.exit(1)
})
