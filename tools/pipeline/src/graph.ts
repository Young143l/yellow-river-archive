/**
 * 知识图谱构建。
 *
 * 两类边：
 *   1. **结构性边**（条目 → 城市/时代/类型/文物/人物/事件/诗词）—— 由结构化字段直接生成
 *   2. **条目间关系边**（culturalLink / nearby）—— 由嵌入相似度与地理距离生成
 *
 * 第 2 类不是可有可无的装饰。没有它，图就是 N 个互不相连的星形，
 * 下游的「标签传播社区发现」（自动文化主题聚合）只能得到平凡解 ——
 * 每个条目自成一个"主题"，等于没做聚合。实测在 5 条样例数据上就是如此。
 */

import type { GraphEdge, GraphNode, HeritageItem, SimilarEntry } from '@yra/shared'

export interface GraphResult {
  readonly nodes: GraphNode[]
  readonly edges: GraphEdge[]
}

/** 稳定去重：同一节点只保留一份 */
class NodeSet {
  private readonly map: Map<string, GraphNode> = new Map<string, GraphNode>()

  add(node: GraphNode): void {
    if (!this.map.has(node.id)) {
      this.map.set(node.id, node)
    }
  }

  values(): GraphNode[] {
    return Array.from(this.map.values())
  }
}

/**
 * 条目间关系边的阈值。
 *
 * 0.5 是向量余弦的常用分界：低于它的"相似"在中文长文本上多半只是
 * 共享了「遗址」「文化」这类通用词。宁可少连几条，也不要让图变成一团乱麻 ——
 * 社区发现对稀疏噪声边很敏感。
 */
const CULTURAL_LINK_THRESHOLD: number = 0.5

/** 地理邻近的阈值：同城且距离在 30km 内视为邻近 */
const NEARBY_KM: number = 30

/** 两点间球面距离（Haversine，公里） */
function distanceKm(lat1: number, lng1: number, lat2: number, lng2: number): number {
  const toRad = (d: number): number => (d * Math.PI) / 180
  const dLat: number = toRad(lat2 - lat1)
  const dLng: number = toRad(lng2 - lng1)
  const a: number =
    Math.sin(dLat / 2) * Math.sin(dLat / 2) +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) * Math.sin(dLng / 2)
  return 6371 * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))
}

export function buildGraph(
  items: readonly HeritageItem[],
  similar: readonly SimilarEntry[] = []
): GraphResult {
  const nodes: NodeSet = new NodeSet()
  const edges: GraphEdge[] = []
  const edgeSeen: Set<string> = new Set<string>()

  const addEdge = (
    from: string,
    to: string,
    rel: GraphEdge['rel'],
    weight: number,
    evidence?: string
  ): void => {
    const key: string = `${from}|${rel}|${to}`
    if (edgeSeen.has(key)) {
      return
    }
    edgeSeen.add(key)
    const edge: GraphEdge = {
      id: `e:${key}`,
      from,
      to,
      rel,
      weight,
      ...(evidence !== undefined ? { evidence } : {}),
    }
    edges.push(edge)
  }

  for (const item of items) {
    const siteId: string = item.id
    nodes.add({
      id: siteId,
      type: 'Site',
      name: item.name,
      aliases: item.aliases,
    })

    // 城市
    const cityId: string = `city:${item.city}`
    nodes.add({ id: cityId, type: 'City', name: item.city, aliases: [] })
    addEdge(siteId, cityId, 'locatedIn', 1)

    // 时代
    const eraId: string = `era:${item.era}`
    nodes.add({ id: eraId, type: 'Era', name: item.era, aliases: [] })
    addEdge(siteId, eraId, 'belongsToEra', 1)

    // 类型
    for (const t of item.types) {
      const typeId: string = `type:${t}`
      nodes.add({ id: typeId, type: 'Type', name: t, aliases: [] })
      addEdge(siteId, typeId, 'hasType', 0.8)
    }

    // 文物
    for (const artifact of item.artifacts) {
      nodes.add({
        id: artifact.id,
        type: 'Artifact',
        name: artifact.name,
        aliases: [],
      })
      addEdge(siteId, artifact.id, 'unearthed', 1, artifact.desc.slice(0, 40))
      if (artifact.museum !== undefined) {
        const museumId: string = `museum:${artifact.museum}`
        nodes.add({ id: museumId, type: 'Museum', name: artifact.museum, aliases: [] })
        addEdge(artifact.id, museumId, 'collectedAt', 0.6)
      }
    }

    // 人物
    for (const figure of item.figures) {
      const figureId: string = `figure:${figure.name}`
      nodes.add({ id: figureId, type: 'Figure', name: figure.name, aliases: [] })
      addEdge(siteId, figureId, 'relatedFigure', 0.6, figure.role)
    }

    // 事件
    for (const ev of item.events) {
      const eventId: string = `event:${item.id}:${ev.year}`
      nodes.add({ id: eventId, type: 'Event', name: ev.title, aliases: [] })
      addEdge(siteId, eventId, 'occurredEvent', 0.5, ev.year)
    }

    // 诗词
    item.poems.forEach((poem, index) => {
      const poemId: string = `poem:${item.id}:${index}`
      nodes.add({
        id: poemId,
        type: 'Poem',
        name: poem.title,
        aliases: [poem.author],
      })
      addEdge(siteId, poemId, 'hasPoem', 0.4)
    })
  }

  // ---- 条目间关系边 ----
  // 文化脉络：由嵌入相似度生成。只保留高于阈值且单向（A→B 与 B→A 只留一条，
  // 避免可视化里出现两条重叠的边）
  const byId = new Map<string, HeritageItem>()
  for (const item of items) {
    byId.set(item.id, item)
  }

  for (const entry of similar) {
    for (const neighbor of entry.neighbors) {
      if (neighbor.score < CULTURAL_LINK_THRESHOLD) {
        continue
      }
      const other: HeritageItem | undefined = byId.get(neighbor.id)
      if (other === undefined) {
        continue
      }
      // 相似度是对称的：A→B 与 B→A 是同一条关系。若不去重，
      // 可视化里会出现两条完全重叠的边（看起来像一条更粗的），
      // 度数统计也会翻倍，进而影响 PageRank 与社区发现。
      // 用「字典序小的 id 在前」统一方向。
      const fromId: string = entry.itemId < neighbor.id ? entry.itemId : neighbor.id
      const toId: string = entry.itemId < neighbor.id ? neighbor.id : entry.itemId
      addEdge(fromId, toId, 'culturalLink', Math.round(neighbor.score * 1000) / 1000, neighbor.reason)
    }
  }

  // 地理邻近：同城且相距 30km 内
  for (let i = 0; i < items.length; i += 1) {
    const a: HeritageItem | undefined = items[i]
    if (a === undefined) {
      continue
    }
    for (let j = i + 1; j < items.length; j += 1) {
      const b: HeritageItem | undefined = items[j]
      if (b === undefined || a.city !== b.city) {
        continue
      }
      const km: number = distanceKm(a.geo.lat, a.geo.lng, b.geo.lat, b.geo.lng)
      if (km > 0 && km <= NEARBY_KM) {
        addEdge(a.id, b.id, 'nearby', Math.round((1 - km / NEARBY_KM) * 100) / 100, `相距约 ${Math.round(km)} 公里`)
      }
    }
  }

  // 节点权重：D1 用归一化度数近似 PageRank
  const degree: Map<string, number> = new Map<string, number>()
  for (const e of edges) {
    degree.set(e.from, (degree.get(e.from) ?? 0) + 1)
    degree.set(e.to, (degree.get(e.to) ?? 0) + 1)
  }
  const maxDegree: number = Math.max(1, ...Array.from(degree.values()))
  const ranked: GraphNode[] = nodes.values().map((n) => ({
    ...n,
    rank: Math.round(((degree.get(n.id) ?? 0) / maxDegree) * 1000) / 1000,
  }))

  return { nodes: ranked, edges }
}
