/**
 * 知识图谱构建。
 *
 * D1 版本：只从结构化字段生成节点与边（城市、时代、类型、文物、人物），
 * 不做实体归一化与关系抽取。D2 版本会在此基础上补充文化脉络、地理邻近等关系，
 * 并用 PageRank 计算节点权重。
 */

import type { GraphEdge, GraphNode, HeritageItem } from '@yra/shared'

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

export function buildGraph(items: readonly HeritageItem[]): GraphResult {
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
