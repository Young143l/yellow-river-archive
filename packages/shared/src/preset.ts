/**
 * 端侧预置包与运行时数据文件的结构定义。
 *
 * 预置包由 tools/pipeline/export 一次构建产出两份产物中的"端侧全量包"，
 * 随 App 安装至 rawfile，首启导入 RDB。
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
  /** 数据源声明，用于"关于页"展示 */
  readonly sourceDeclarations: readonly string[]
  /** 生成该包的流水线版本 */
  readonly pipelineVersion: string
}

/** chunks.jsonl 中每一行的结构 */
export type PresetChunkLine = Chunk

/** graph.json */
export interface PresetGraph {
  readonly nodes: readonly GraphNode[]
  readonly edges: readonly GraphEdge[]
}

/** similar.json */
export interface PresetSimilar {
  readonly entries: readonly SimilarEntry[]
}
