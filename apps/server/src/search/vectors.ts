/**
 * 内存向量库。
 *
 * 取舍（ADR-005 / 设计文档 4.3）：全量片段量级在 10³，**暴力检索足够快**，
 * 不引入 FAISS / hnswlib 这类原生依赖。1500 片段 × 1024 维的点积约 1ms。
 *
 * 关键性质：构建期的向量已做 L2 归一化（实测范数 1.0000），
 * 因此**点积即余弦**，省掉每次查询的模长计算。
 */

import type { Db } from '../db/index'

export interface VectorHit {
  readonly chunkId: string
  readonly score: number
}

export class VectorStore {
  /** 片段向量，与 ids 同序，用于紧凑遍历 */
  private ids: string[] = []
  private data: Float32Array = new Float32Array(0)
  private dim: number = 0

  get size(): number {
    return this.ids.length
  }

  get dimension(): number {
    return this.dim
  }

  /** 从数据库载入全部向量 */
  static load(db: Db): VectorStore {
    const store = new VectorStore()
    const rows = db
      .prepare('SELECT chunk_id, dim, vec FROM chunk_vectors')
      .all() as { chunk_id: string; dim: number; vec: Uint8Array }[]

    if (rows.length === 0) {
      return store
    }

    const dim: number = rows[0]?.dim ?? 0
    const ids: string[] = []
    const flat = new Float32Array(rows.length * dim)

    let i = 0
    for (const row of rows) {
      const values = new Float32Array(
        row.vec.buffer.slice(row.vec.byteOffset, row.vec.byteOffset + row.vec.byteLength)
      )
      if (values.length !== dim) {
        continue
      }
      flat.set(values, i * dim)
      ids.push(row.chunk_id)
      i += 1
    }

    store.ids = ids
    store.data = flat.subarray(0, i * dim)
    store.dim = dim
    return store
  }

  /**
   * 点积检索。
   * 查询向量必须同样已归一化；未归一化时结果只是按模长缩放，排序仍可用，
   * 但分数不可跨查询比较 —— 调用方需保证归一化。
   */
  search(query: Float32Array, topK: number, allow?: ReadonlySet<string>): VectorHit[] {
    if (this.ids.length === 0 || query.length !== this.dim) {
      return []
    }
    const k: number = Math.min(topK, this.ids.length)
    // 小顶堆的简易替代：先取满再整体排序。topK 很小（≤50），排序开销可忽略
    const scores = new Float64Array(this.ids.length)
    for (let i = 0; i < this.ids.length; i += 1) {
      const base: number = i * this.dim
      let sum: number = 0
      for (let d = 0; d < this.dim; d += 1) {
        sum += (this.data[base + d] ?? 0) * (query[d] ?? 0)
      }
      scores[i] = sum
    }

    const order: number[] = []
    for (let i = 0; i < this.ids.length; i += 1) {
      const id: string = this.ids[i] ?? ''
      if (allow !== undefined && !allow.has(id)) {
        continue
      }
      order.push(i)
    }
    order.sort((a, b) => (scores[b] ?? 0) - (scores[a] ?? 0))

    const out: VectorHit[] = []
    for (const idx of order.slice(0, k)) {
      const id: string = this.ids[idx] ?? ''
      const score: number = scores[idx] ?? 0
      if (id.length > 0) {
        out.push({ chunkId: id, score })
      }
    }
    return out
  }

  /** 取单个片段的向量（关联推荐用） */
  get(chunkId: string): Float32Array | undefined {
    const idx: number = this.ids.indexOf(chunkId)
    if (idx < 0) {
      return undefined
    }
    return this.data.subarray(idx * this.dim, (idx + 1) * this.dim)
  }
}
