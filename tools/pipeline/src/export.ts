/**
 * 导出端侧预置包。
 *
 * 产物写入端侧工程的 rawfile/data/，随 App 安装预置到本地，首启导入 RDB。
 * 同一份"内容切片"在 D3 阶段还会导出服务端检索索引（见 ADR-010），
 * 两者必须由同一次构建产出，以保证 dataVersion 一致。
 */

import { createHash } from 'node:crypto'
import { mkdir, writeFile } from 'node:fs/promises'
import { join } from 'node:path'

import type {
  Chunk,
  GraphEdge,
  GraphNode,
  HeritageItem,
  PresetMeta,
  SimilarEntry,
  VocabEntry,
} from '@yra/shared'

/** 流水线自身版本，写入 meta 便于排查产物来源 */
const PIPELINE_VERSION: string = '0.1.0'

export interface ExportInput {
  readonly items: readonly HeritageItem[]
  readonly chunks: readonly Chunk[]
  readonly nodes: readonly GraphNode[]
  readonly edges: readonly GraphEdge[]
  readonly similar: readonly SimilarEntry[]
  readonly vocab: readonly VocabEntry[]
  readonly imageCount: number
  readonly outDir: string
  readonly now?: Date
}

export interface ExportResult {
  readonly files: { readonly name: string; readonly bytes: number }[]
  readonly meta: PresetMeta
}

function todayVersion(now: Date): string {
  const y: number = now.getFullYear()
  const m: number = now.getMonth() + 1
  const d: number = now.getDate()
  return `${y}.${m}.${d}`
}

export async function exportPreset(input: ExportInput): Promise<ExportResult> {
  const now: Date = input.now ?? new Date()

  const itemsJson: string = JSON.stringify(input.items, null, 2)
  const contentHash: string = createHash('sha256').update(itemsJson).digest('hex').slice(0, 16)

  const sourceTitles: Set<string> = new Set<string>()
  for (const item of input.items) {
    for (const s of item.sources) {
      sourceTitles.add(s.title)
    }
  }

  const meta: PresetMeta = {
    dataVersion: todayVersion(now),
    contentHash,
    generatedAt: now.toISOString(),
    itemCount: input.items.length,
    chunkCount: input.chunks.length,
    imageCount: input.imageCount,
    vocabSize: input.vocab.length,
    sourceDeclarations: Array.from(sourceTitles).sort(),
    pipelineVersion: PIPELINE_VERSION,
  }

  const payloads: { name: string; content: string }[] = [
    { name: 'items.json', content: itemsJson },
    { name: 'chunks.jsonl', content: input.chunks.map((c) => JSON.stringify(c)).join('\n') + '\n' },
    {
      name: 'graph.json',
      content: JSON.stringify({ nodes: input.nodes, edges: input.edges }, null, 2),
    },
    { name: 'similar.json', content: JSON.stringify({ entries: input.similar }, null, 2) },
    { name: 'vocab.json', content: JSON.stringify({ entries: input.vocab }, null, 2) },
    { name: 'meta.json', content: JSON.stringify(meta, null, 2) },
  ]

  await mkdir(input.outDir, { recursive: true })

  const files: { name: string; bytes: number }[] = []
  for (const p of payloads) {
    await writeFile(join(input.outDir, p.name), p.content, 'utf8')
    files.push({ name: p.name, bytes: Buffer.byteLength(p.content, 'utf8') })
  }

  return { files, meta }
}
