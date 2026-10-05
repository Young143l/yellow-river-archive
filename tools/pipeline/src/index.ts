/**
 * 数据流水线 CLI。
 *
 *   pnpm data:build    校验 + 分块 + 构图 + 预计算 + 导出端侧预置包
 *   pnpm data:status   只做校验与分布统计（不写文件）
 *   pnpm data:verify   严格校验，有问题则退出码非零（pre-push / CI 用）
 *
 * 本文件只做编排，具体步骤在各自模块里。
 */

import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

import { buildChunks } from './chunk'
import { runEmbedding, type EmbedReport } from './embed'
import { exportPreset } from './export'
import { buildGraph } from './graph'
import { computeDistribution, loadSites, type Distribution, type LoadIssue } from './load-sites'
import { buildSimilar } from './similar'
import { loadSitesDoc, reportSites, type SitesReport } from './sites'
import {
  lintAll,
  lintChunks,
  lintVocab,
  type LintIssue,
  type LintReport,
} from './lint'
import {
  buildVocab,
  extractTermsFromItems,
  loadLexicon,
  Tokenizer,
  type VocabEntry,
} from './tokenize'

const HERE: string = dirname(fileURLToPath(import.meta.url))
const REPO_ROOT: string = resolve(HERE, '..', '..', '..')
const SITES_DIR: string = join(REPO_ROOT, 'packages', 'data', 'sites')
const SITES_INDEX: string = join(REPO_ROOT, 'packages', 'data', 'sites.yaml')
const SOURCES_DIR: string = join(REPO_ROOT, 'packages', 'data', 'sources')
const LEXICON: string = join(REPO_ROOT, 'packages', 'data', 'lexicon.txt')

/** 端侧词表规模上限（约 100KB，见设计文档 §4.6 体积预算） */
const VOCAB_TOP_N: number = 12000

/** 嵌入缓存与产物路径（derived 与 .cache 均已 gitignore） */
const CACHE_FILE: string = join(REPO_ROOT, 'packages', 'data', '.cache', 'embeddings.jsonl')
const EMBED_OUT_DIR: string = join(REPO_ROOT, 'packages', 'data', 'derived', 'embeddings')
const RAW_OUT_DIR: string = join(
  REPO_ROOT,
  'harmony',
  'YellowRiverArchive',
  'entry',
  'src',
  'main',
  'resources',
  'rawfile',
  'data'
)

function printIssues(issues: readonly LoadIssue[]): void {
  for (const issue of issues) {
    console.error(`  [${issue.file}]`)
    for (const p of issue.problems) {
      console.error(`      ${p}`)
    }
  }
}

function printDistribution(d: Distribution): void {
  const line = (label: string, rows: readonly { key: string; count: number }[]): void => {
    const body: string = rows.map((r) => `${r.key} ${r.count}`).join('  ｜  ')
    console.log(`  ${label}  ${body}`)
  }
  console.log(`  档案总数  ${d.total}`)
  line('城市分布 ', d.byCity)
  line('时代分布 ', d.byEra)
  line('类型分布 ', d.byType)
  console.log(`  配图总数  ${d.imageCount}  ｜  含诗词条目  ${d.poemCovered}`)
}

function printLintIssues(issues: readonly LintIssue[], level: 'error' | 'warning'): void {
  const selected: LintIssue[] = issues.filter((i) => i.level === level)
  if (selected.length === 0) {
    return
  }
  console.log('')
  console.log(level === 'error' ? '[lint] 硬错误（必须修）' : '[lint] 软提醒（建议修）')
  for (const issue of selected) {
    console.log(`  ${issue.target} ・ ${issue.field}  ${issue.message}`)
  }
}

async function main(): Promise<void> {
  const command: string = process.argv[2] ?? 'build'

  // lint 子命令：质量体检，不写任何文件
  if (command === 'lint') {
    const phase: 'dev' | 'final' = process.argv.includes('--final') ? 'final' : 'dev'
    const loaded = await loadSites(SITES_DIR)
    const doc = await loadSitesDoc(SITES_INDEX)

    const report: LintReport = await lintAll({
      items: loaded.items,
      allocation: doc.meta.allocation,
      sourcesDir: SOURCES_DIR,
      contentDir: SITES_DIR,
      indexEntries: doc.sites,
      phase,
    })

    const chunks = buildChunks(loaded.items)
    const lexicon: string[] = await loadLexicon(LEXICON)
    const allTerms: string[] = Array.from(
      new Set<string>([...lexicon, ...extractTermsFromItems(loaded.items)])
    )
    const tokenizer: Tokenizer = Tokenizer.create(allTerms)
    const tokenized = chunks.map((c) => ({ ...c, tokens: tokenizer.tokenize(c.text) }))
    const vocab: VocabEntry[] = buildVocab(
      tokenized.map((c) => [...c.tokens]),
      VOCAB_TOP_N
    )

    const extras: LintIssue[] = [...lintChunks(tokenized), ...lintVocab(vocab)]
    const allIssues: LintIssue[] = [...report.issues, ...extras]
    const errorCount: number = allIssues.filter((i) => i.level === 'error').length
    const warningCount: number = allIssues.filter((i) => i.level === 'warning').length

    console.log('[lint] 数据质检')
    console.log(`  阶段 ${phase === 'final' ? '交付期（覆盖度按硬错误计）' : '开发期（覆盖度按提醒计）'}`)
    console.log(`  条目 ${report.stats.items} 条 ｜ 有来源摘录 ${report.stats.itemsWithSource} 条`)
    console.log(`  分块 ${tokenized.length} 个 ｜ 词表 ${vocab.length} 词`)
    console.log(`  查重命中 ${report.stats.ngramHits} 处 ｜ 含占位图条目 ${report.stats.placeholderItems} 条`)
    if (report.stats.itemsWithSource === 0) {
      console.log('')
      console.log('  注意：尚无来源摘录（packages/data/sources/<id>.md），')
      console.log('        本次未执行 n-gram 查重。写作阶段必须补齐摘录文件，否则无法把住抄袭线。')
    }

    printLintIssues(allIssues, 'error')
    printLintIssues(allIssues, 'warning')

    console.log('')
    console.log(`[lint] 硬错误 ${errorCount} 项，软提醒 ${warningCount} 项`)
    if (errorCount > 0) {
      process.exit(1)
    }
    return
  }

  // sites 子命令：只体检清单台账，不碰正文
  if (command === 'sites') {
    const doc = await loadSitesDoc(SITES_INDEX)
    const report: SitesReport = reportSites(doc, SITES_DIR)
    console.log('[pipeline] 清单体检')
    for (const line of report.lines) {
      console.log(`  ${line}`)
    }
    if (report.problems.length > 0) {
      console.log('')
      console.log('[pipeline] 待处理事项：')
      for (const p of report.problems) {
        console.log(`  - ${p}`)
      }
    } else {
      console.log('')
      console.log('[pipeline] 清单体检全部通过')
    }
    return
  }

  // embed 子命令：只跑嵌入，不重建预置包（供分段试跑与补跑）
  if (command === 'embed') {
    const limitArg: string | undefined = process.argv.find((a) => a.startsWith('--limit='))
    const limit: number | undefined =
      limitArg !== undefined ? Number.parseInt(limitArg.slice('--limit='.length), 10) : undefined

    const loaded = await loadSites(SITES_DIR)
    if (loaded.issues.length > 0) {
      printIssues(loaded.issues)
      console.error('[pipeline] 档案校验未通过，已中止嵌入')
      process.exit(1)
    }

    const chunksForEmbed = buildChunks(loaded.items)
    const report: EmbedReport = await runEmbedding({
      items: loaded.items,
      chunks: chunksForEmbed,
      cacheFile: CACHE_FILE,
      outDir: EMBED_OUT_DIR,
      limit,
    })
    console.log(
      `[embed] 完成：共 ${report.total} 个片段，缓存命中 ${report.cached}，本次编码 ${report.embedded}，失败 ${report.failed}`
    )
    console.log(
      `[embed] 模型 ${report.model} @ ${report.dim} 维 ｜ 耗时 ${(report.elapsedMs / 1000).toFixed(1)}s ｜ token ${report.tokens}`
    )
    console.log(`[embed] 产物 -> ${EMBED_OUT_DIR.replace(REPO_ROOT + '/', '')}`)
    if (report.failed > 0) {
      process.exit(1)
    }
    return
  }

  const { items, issues } = await loadSites(SITES_DIR)
  console.log(`[pipeline] 读取 ${SITES_DIR.replace(REPO_ROOT + '/', '')}`)
  console.log(`[pipeline] 通过校验 ${items.length} 条，问题 ${issues.length} 条`)

  if (issues.length > 0) {
    printIssues(issues)
  }

  if (command === 'verify' && issues.length > 0) {
    console.error('[pipeline] 校验未通过，已中止')
    process.exit(1)
  }

  const distribution: Distribution = computeDistribution(items)
  console.log('[pipeline] 数据分布：')
  printDistribution(distribution)

  if (command === 'status' || command === 'verify') {
    return
  }

  if (items.length === 0) {
    console.error('[pipeline] 没有可用条目，跳过导出')
    process.exit(1)
  }

  const chunks = buildChunks(items)

  // 分词：jieba + 领域词典前向最大匹配
  const lexicon: string[] = await loadLexicon(LEXICON)
  const autoTerms: string[] = extractTermsFromItems(items)
  const allTerms: string[] = Array.from(new Set<string>([...lexicon, ...autoTerms]))
  const tokenizer: Tokenizer = Tokenizer.create(allTerms)
  const tokenized = chunks.map((c) => ({ ...c, tokens: tokenizer.tokenize(c.text) }))
  const vocab: VocabEntry[] = buildVocab(
    tokenized.map((c) => [...c.tokens]),
    VOCAB_TOP_N
  )
  const avgTokens: number =
    tokenized.length > 0
      ? Math.round(tokenized.reduce((sum, c) => sum + c.tokens.length, 0) / tokenized.length)
      : 0

  const graph = buildGraph(items)
  const similar = buildSimilar(items)

  console.log(
    `[pipeline] 分块 ${chunks.length} 个 ｜ 领域词 ${allTerms.length} 条 ｜ 平均 ${avgTokens} 词/片段 ｜ 词表 ${vocab.length} 词`
  )
  console.log(
    `[pipeline] 图谱 ${graph.nodes.length} 节点 / ${graph.edges.length} 连边 ｜ 相似条目 ${similar.length} 条`
  )

  const imageCount: number = items.reduce((sum, i) => sum + i.images.length, 0)
  const result = await exportPreset({
    items,
    chunks: tokenized,
    nodes: graph.nodes,
    edges: graph.edges,
    similar,
    vocab,
    imageCount,
    outDir: RAW_OUT_DIR,
  })

  console.log(
    `[pipeline] 已导出预置包 -> ${RAW_OUT_DIR.replace(REPO_ROOT + '/', '')}（dataVersion ${result.meta.dataVersion}，contentHash ${result.meta.contentHash}）`
  )
  for (const f of result.files) {
    console.log(`      ${f.name}  ${(f.bytes / 1024).toFixed(1)}KB`)
  }
}

main().catch((err: unknown) => {
  console.error('[pipeline] 失败：', err instanceof Error ? err.message : err)
  process.exit(1)
})
