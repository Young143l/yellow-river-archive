/**
 * 本文件由 tools/gen 自动生成，请勿手改。
 * 源文件：packages/shared/src/preset.ts
 * 重新生成：pnpm gen:arkts
 */
import type { GraphEdge, GraphNode, SimilarEntry, Chunk } from './models'

/** 预置包元信息（meta.json） */
export interface PresetMeta {
  /** 数据版本，形如 2026.10.1 */
  readonly dataVersion: string
  /** 内容哈希，用于校验端侧包与服务端索引是否同源 */
  readonly contentHash: string
  /** 生成时间，ISO 8601 */
  readonly generatedAt: string
  readonly itemCount: number
  readonly chunkCount: number
  readonly imageCount: number
  /** 词表规模，供端侧自检 */
  readonly vocabSize: number
  /** 数据源声明，用于"关于页"展示 */
  readonly sourceDeclarations: string[]
  /** 生成该包的流水线版本 */
  readonly pipelineVersion: string
}

/** chunks.jsonl 中每一行的结构 */
export type PresetChunkLine = Chunk

/** graph.json */
export interface PresetGraph {
  readonly nodes: GraphNode[]
  readonly edges: GraphEdge[]
}

/** similar.json */
export interface PresetSimilar {
  readonly entries: SimilarEntry[]
}

/** 词表条目：端侧用它对查询串做词典最大匹配 */
export interface VocabEntry {
  readonly word: string
  readonly freq: number
}

/** vocab.json */
export interface PresetVocab {
  readonly entries: VocabEntry[]
}
