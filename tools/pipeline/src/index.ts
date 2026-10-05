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
import { exportPreset } from './export'
import { buildGraph } from './graph'
import { computeDistribution, loadSites, type Distribution, type LoadIssue } from './load-sites'
import { buildSimilar } from './similar'
import { loadSitesDoc, reportSites, type SitesReport } from './sites'
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
const LEXICON: string = join(REPO_ROOT, 'packages', 'data', 'lexicon.txt')

/** 端侧词表规模上限（约 100KB，见设计文档 §4.6 体积预算） */
const VOCAB_TOP_N: number = 12000
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

async function main(): Promise<void> {
  const command: string = process.argv[2] ?? 'build'

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
