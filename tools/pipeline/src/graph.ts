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

/** 地理邻近的阈值：130km 内视为邻近 */
const NEARBY_KM: number = 130

/**
 * 每条规则为每个条目保留的最近邻居数（kNN）。
 *
 * 为什么要设上界：规则全开时，80 条数据在 130km 半径内的两两组合可达数百条边，
 * 图会烂成一团毛线，社区发现也会被噪声淹没。kNN 让每个节点的度数受控，
 * 同时天然做到「稠密区分得清、稀疏区也连得上」—— 5 条数据时照样能连通。
 */
const KNN_K: number = 3

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

  // ---- 条目间关系：四条规则 + kNN ----
  //
  // 修复的问题：原先只有「同城且 <30km」一条地理规则，而五个遗址恰好分属五个城市，
  // 于是**一条边都生成不出来**，5 条数据形成 4 个互不相连的孤岛
  // （实测连通分量 = 4）。知识图谱画出来必然是四团分离的东西，
  // 无论用什么布局算法都读不出结构。跨遗址关系是可视化的前提，不是装饰。
  //
  // 设计取舍：每条规则各取最近的 k 个邻居再做合并，而不是「满足条件全连」。
  // 全连在 80 条数据时会产出数百条边，图会烂掉。

  interface Candidate {
    readonly other: string
    readonly rel: GraphEdge['rel']
    readonly weight: number
    readonly evidence: string
    readonly order: number // 排序用：越小越优先
  }

  /** 把两条理由合并，相同的不重复列 */
  const mergeEvidence = (a: string, b: string): string => {
    if (a === b) {
      return a
    }
    const seenParts: Set<string> = new Set<string>(a.split('；'))
    for (const part of b.split('；')) {
      seenParts.add(part)
    }
    return Array.from(seenParts).join('；')
  }

  /** 按规则收集候选边，再对每对条目取最强的一条 */
  const best: Map<string, Candidate> = new Map<string, Candidate>()
  const offer = (from: string, to: string, rel: GraphEdge['rel'], weight: number, evidence: string, order: number): void => {
    const lo: string = from < to ? from : to
    const hi: string = from < to ? to : from
    const key: string = `${lo}|${hi}`
    const prev: Candidate | undefined = best.get(key)
    // 同一对条目可能同时满足多条规则（例如既是同时代又同类型）。
    // 取 weight 最高的那条作为边的类型，但把其余理由合并进 evidence —— 
    // 这样它仍是一条边，不会重复，也不会丢掉「为什么相连」的解释。
    if (prev === undefined) {
      best.set(key, { other: hi, rel, weight, evidence, order })
      return
    }
    if (weight > prev.weight) {
      best.set(key, {
        other: hi,
        rel,
        weight,
        evidence: mergeEvidence(evidence, prev.evidence),
        order,
      })
    } else {
      best.set(key, { ...prev, evidence: mergeEvidence(prev.evidence, evidence) })
    }
  }

  for (let i = 0; i < items.length; i += 1) {
    const a: HeritageItem | undefined = items[i]
    if (a === undefined) {
      continue
    }
    // 收集 a 与其余条目的所有候选关系
    const cands: Candidate[] = []
    for (let j = 0; j < items.length; j += 1) {
      if (i === j) {
        continue
      }
      const b: HeritageItem | undefined = items[j]
      if (b === undefined) {
        continue
      }
      // 同时代
      if (a.era === b.era) {
        cands.push({ other: b.id, rel: 'culturalLink', weight: 0.6, evidence: `同属${a.era}时期`, order: 1 })
      }
      // 同城市
      if (a.city === b.city) {
        cands.push({ other: b.id, rel: 'culturalLink', weight: 0.7, evidence: `同处${a.city}`, order: 0 })
      }
      // 同类型
      const shared: string[] = a.types.filter((tp) => b.types.includes(tp))
      if (shared.length > 0) {
        cands.push({ other: b.id, rel: 'culturalLink', weight: 0.5, evidence: `同为${shared[0]}`, order: 2 })
      }
      // 地理近邻
      const km: number = distanceKm(a.geo.lat, a.geo.lng, b.geo.lat, b.geo.lng)
      if (km > 0 && km <= NEARBY_KM) {
        cands.push({
          other: b.id,
          rel: 'nearby',
          weight: Math.round((1 - km / NEARBY_KM) * 100) / 100,
          evidence: `相距约 ${Math.round(km)} 公里`,
          order: 3 + km / NEARBY_KM,
        })
      }
    }

    // 同一目标可能被多条规则命中：按目标去重，保留最优理由
    const byTarget: Map<string, Candidate> = new Map<string, Candidate>()
    for (const c of cands) {
      const prev: Candidate | undefined = byTarget.get(c.other)
      if (prev === undefined || c.order < prev.order) {
        byTarget.set(c.other, c)
      }
    }
    // 取最近/最强的 k 个
    const picked: Candidate[] = Array.from(byTarget.values())
      .sort((x, y) => x.order - y.order)
      .slice(0, KNN_K)

    for (const c of picked) {
      offer(a.id, c.other, c.rel, c.weight, c.evidence, c.order)
    }
  }

  for (const [key, c] of best) {
    const parts: string[] = key.split('|')
    const from: string = parts[0]
    const to: string = parts[1]
    addEdge(from, to, c.rel, c.weight, c.evidence)
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
