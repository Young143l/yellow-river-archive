/**
 * 服务端数据导入。
 *
 * 数据来源与端侧**完全同源**：端侧预置包（items / chunks / graph）+ 构建期的
 * 嵌入产物。这正是 ADR-010 的落地——一次构建产出两份产物，服务端那份只是
 * "为检索切出的切片"，因而天然不会出现"手机能搜到、服务器搜不到"。
 *
 * 幂等：按 meta.dataVersion 比对，版本一致直接跳过。
 */

import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'

import { getMeta, putMeta, type Db } from './index'
import { MetaKeys, TRUNCATE_STATEMENTS } from './schema'

export interface ImportSummary {
  readonly skipped: boolean
  readonly dataVersion: string
  readonly items: number
  readonly chunks: number
  readonly vectors: number
  readonly nodes: number
  readonly edges: number
  readonly elapsedMs: number
}

interface PresetMeta {
  readonly dataVersion: string
  readonly contentHash: string
  readonly itemCount: number
  readonly chunkCount: number
}

interface PresetItem {
  readonly id: string
  readonly name: string
  readonly city: string
  readonly era: string
  readonly eraRange?: number[]
  readonly types: string[]
  readonly level?: string
  readonly summary: string
  readonly images?: { readonly path?: string }[]
}

interface PresetChunk {
  readonly id: string
  readonly itemId: string
  readonly section: string
  readonly seq: number
  readonly text: string
  readonly tokens: string[]
}

interface PresetGraphNode {
  readonly id: string
  readonly type: string
  readonly name: string
  readonly aliases: string[]
  readonly rank?: number
}

interface PresetGraphEdge {
  readonly id: string
  readonly from: string
  readonly to: string
  readonly rel: string
  readonly weight: number
  readonly evidence?: string
}

interface EmbeddingIndexEntry {
  readonly chunkId: string
  readonly offset: number
  readonly dim: number
}

interface EmbeddingIndex {
  readonly model: string
  readonly dim: number
  readonly count: number
  readonly entries: EmbeddingIndexEntry[]
}

function readJson<T>(path: string): T {
  return JSON.parse(readFileSync(path, 'utf8')) as T
}

function readJsonl<T>(path: string): T[] {
  const raw: string = readFileSync(path, 'utf8')
  const out: T[] = []
  for (const line of raw.split('\n')) {
    const trimmed: string = line.trim()
    if (trimmed.length > 0) {
      out.push(JSON.parse(trimmed) as T)
    }
  }
  return out
}

export function importPreset(db: Db, presetDir: string, embeddingsDir: string): ImportSummary {
  const started: number = Date.now()

  const metaPath: string = join(presetDir, 'meta.json')
  if (!existsSync(metaPath)) {
    throw new Error(`找不到预置包 meta.json：${metaPath}（先跑 pnpm data:build）`)
  }
  const meta: PresetMeta = readJson<PresetMeta>(metaPath)

  const stored: string | undefined = getMeta(db, MetaKeys.DATA_VERSION)
  if (stored === meta.dataVersion) {
    const itemCount: number = Number.parseInt(getMeta(db, MetaKeys.ITEM_COUNT) ?? '0', 10)
    const chunkCount: number = Number.parseInt(getMeta(db, MetaKeys.CHUNK_COUNT) ?? '0', 10)
    return {
      skipped: true,
      dataVersion: meta.dataVersion,
      items: itemCount,
      chunks: chunkCount,
      vectors: chunkCount,
      nodes: 0,
      edges: 0,
      elapsedMs: Date.now() - started,
    }
  }

  const items: PresetItem[] = readJson<PresetItem[]>(join(presetDir, 'items.json'))
  const chunks: PresetChunk[] = readJsonl<PresetChunk>(join(presetDir, 'chunks.jsonl'))
  const graph = readJson<{ nodes: PresetGraphNode[]; edges: PresetGraphEdge[] }>(
    join(presetDir, 'graph.json')
  )

  db.exec('BEGIN')
  try {
    for (const statement of TRUNCATE_STATEMENTS) {
      db.exec(statement)
    }

    const insertItem = db.prepare(
      `INSERT INTO items (id, name, city, era, era_min, era_max, types, level, summary, cover, payload)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
    )
    for (const item of items) {
      insertItem.run(
        item.id,
        item.name,
        item.city,
        item.era,
        item.eraRange?.[0] ?? 0,
        item.eraRange?.[1] ?? 0,
        JSON.stringify(item.types),
        item.level ?? '',
        item.summary,
        // 主图只存路径引用 —— 图片二进制是端侧专属（ADR-024）
        item.images?.[0]?.path ?? '',
        JSON.stringify(item)
      )
    }

    const insertChunk = db.prepare(
      'INSERT INTO chunks (id, item_id, section, seq, text, tokens) VALUES (?, ?, ?, ?, ?, ?)'
    )
    const insertFts = db.prepare('INSERT INTO chunks_fts (chunk_id, tokens) VALUES (?, ?)')
    for (const chunk of chunks) {
      insertChunk.run(chunk.id, chunk.itemId, chunk.section, chunk.seq, chunk.text, chunk.tokens.join(' '))
      // FTS5 索引的是分词结果（ADR-006）：BM25 的 IDF 才有意义
      insertFts.run(chunk.id, chunk.tokens.join(' '))
    }

    const insertNode = db.prepare(
      'INSERT INTO kg_nodes (id, type, name, aliases, rank) VALUES (?, ?, ?, ?, ?)'
    )
    for (const node of graph.nodes) {
      insertNode.run(node.id, node.type, node.name, node.aliases.join(' '), node.rank ?? 0)
    }

    const insertEdge = db.prepare(
      'INSERT INTO kg_edges (id, src, dst, rel, weight, evidence) VALUES (?, ?, ?, ?, ?, ?)'
    )
    for (const edge of graph.edges) {
      insertEdge.run(edge.id, edge.from, edge.to, edge.rel, edge.weight, edge.evidence ?? '')
    }

    // ---- 向量 ----
    let vectorCount: number = 0
    let embeddingModel: string = ''
    let embeddingDim: number = 0
    const indexPath: string = join(embeddingsDir, 'index.json')
    const vectorPath: string = join(embeddingsDir, 'vectors.f32')
    if (existsSync(indexPath) && existsSync(vectorPath)) {
      const index: EmbeddingIndex = readJson<EmbeddingIndex>(indexPath)
      const buffer: Buffer = readFileSync(vectorPath)
      embeddingModel = index.model
      embeddingDim = index.dim

      const insertVector = db.prepare(
        'INSERT OR REPLACE INTO chunk_vectors (chunk_id, dim, vec) VALUES (?, ?, ?)'
      )
      for (const entry of index.entries) {
        const start: number = entry.offset * 4
        const end: number = start + entry.dim * 4
        if (end > buffer.length) {
          continue
        }
        const slice: Uint8Array = new Uint8Array(buffer.subarray(start, end))
        insertVector.run(entry.chunkId, entry.dim, slice)
        vectorCount += 1
      }
    }

    db.exec('COMMIT')

    putMeta(db, MetaKeys.DATA_VERSION, meta.dataVersion)
    putMeta(db, MetaKeys.CONTENT_HASH, meta.contentHash)
    putMeta(db, MetaKeys.IMPORTED_AT, String(Date.now()))
    putMeta(db, MetaKeys.ITEM_COUNT, String(items.length))
    putMeta(db, MetaKeys.CHUNK_COUNT, String(chunks.length))
    if (embeddingModel.length > 0) {
      putMeta(db, MetaKeys.EMBEDDING_MODEL, embeddingModel)
      putMeta(db, MetaKeys.EMBEDDING_DIM, String(embeddingDim))
    }

    return {
      skipped: false,
      dataVersion: meta.dataVersion,
      items: items.length,
      chunks: chunks.length,
      vectors: vectorCount,
      nodes: graph.nodes.length,
      edges: graph.edges.length,
      elapsedMs: Date.now() - started,
    }
  } catch (err) {
    db.exec('ROLLBACK')
    throw err
  }
}
