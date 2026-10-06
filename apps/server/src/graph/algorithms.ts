/**
 * 图算法。
 *
 * 全部为朴素实现，不引第三方图库 —— 图谱规模在 200-500 节点量级，
 * 朴素实现的耗时是毫秒级，而引入图库要付出打包体积与 API 适配成本。
 * 若将来规模上到万级节点，再换 CSR + 稀疏矩阵乘也不迟。
 *
 * 三个算法的用途：
 *   - PageRank：节点权重，决定可视化里节点的大小与推荐排序
 *   - 标签传播：**自动文化主题聚合**（创新点，无需人工打标）
 *   - BFS 最短路：路径探索，如「从仰韶到宋的文化脉络」
 */

import type { Community, GraphEdge, GraphNode, GraphPathChain } from '@yra/shared'

export interface GraphData {
  readonly nodes: readonly GraphNode[]
  readonly edges: readonly GraphEdge[]
}

/** 邻接表：id -> 邻居 id 列表（无向，两个方向都记） */
function buildAdjacency(edges: readonly GraphEdge[]): Map<string, string[]> {
  const adjacency = new Map<string, string[]>()
  const link = (from: string, to: string): void => {
    const list: string[] = adjacency.get(from) ?? []
    if (!list.includes(to)) {
      list.push(to)
    }
    adjacency.set(from, list)
  }
  for (const edge of edges) {
    link(edge.from, edge.to)
    link(edge.to, edge.from)
  }
  return adjacency
}

/**
 * PageRank。
 *
 * damping 0.85 是论文原值；收敛阈值 1e-4 让 20 次左右迭代即可稳定。
 * **不做悬挂节点补偿**（dangling node redistribution）——挂出度为 0 的节点在
 * 本图谱里不存在（每个节点至少有一条边），加了反而多一层没人看的代码。
 */
export function pageRank(
  data: GraphData,
  damping: number = 0.85,
  maxIterations: number = 30
): Map<string, number> {
  const n: number = data.nodes.length
  const rank = new Map<string, number>()
  if (n === 0) {
    return rank
  }

  const initial: number = 1 / n
  for (const node of data.nodes) {
    rank.set(node.id, initial)
  }

  const adjacency: Map<string, string[]> = buildAdjacency(data.edges)
  const outDegree = new Map<string, number>()
  for (const node of data.nodes) {
    outDegree.set(node.id, (adjacency.get(node.id) ?? []).length)
  }

  for (let iter = 0; iter < maxIterations; iter += 1) {
    const next = new Map<string, number>()
    let delta: number = 0

    for (const node of data.nodes) {
      let incoming: number = 0
      const neighbors: string[] = adjacency.get(node.id) ?? []
      for (const neighbor of neighbors) {
        const degree: number = outDegree.get(neighbor) ?? 0
        if (degree > 0) {
          incoming += (rank.get(neighbor) ?? 0) / degree
        }
      }
      const value: number = (1 - damping) / n + damping * incoming
      next.set(node.id, value)
      delta += Math.abs(value - (rank.get(node.id) ?? 0))
    }

    for (const [id, value] of next.entries()) {
      rank.set(id, value)
    }
    if (delta < 1e-4) {
      break
    }
  }

  return rank
}

/**
 * 参与社区发现的「语义骨架边」。
 *
 * 为什么要把叶子边排除：条目 → 文物/事件/诗词 这些边把图变成了星形 ——
 * 每个中心节点被自己的一堆只连它一个的卫星节点"投票"，
 * 跨条目的那条弱关系边（相似度或同城）根本投不过。实测结果就是
 * 「每个条目自成一个社区」，等于没做聚合。
 *
 * 只保留骨架边（城市 / 时代 / 类型 / 条目间关系）后，同属仰韶的两个遗址
 * 会因为共享「仰韶」节点而被聚到一起 —— 这才是「自动文化主题聚合」要的效果。
 */
const SEMANTIC_RELATIONS: readonly string[] = [
  'locatedIn',
  'belongsToEra',
  'hasType',
  'culturalLink',
  'nearby',
]

/** 取出只含骨架边的图 */
function coreGraph(data: GraphData): GraphData {
  return {
    nodes: data.nodes,
    edges: data.edges.filter((e) => SEMANTIC_RELATIONS.includes(e.rel)),
  }
}

/**
 * 标签传播社区发现。
 *
 * 每个节点初始携带自己的 id 作标签，迭代时改为「邻居里出现最多的标签」。
 * 平局用 id 字典序兜底，保证结果**确定性** —— 否则同一次数据两次运行会得到
 * 不同的社区划分，可视化会出现「刷新一次主题变一次」的怪异现象。
 *
 * 这是赛题「自动文化主题聚合」的实现核心：不需要人工打标，
 * 图谱结构自己会聚出「唐三彩」「早期都邑」这类主题。
 */
export function detectCommunities(input: GraphData, maxIterations: number = 20): Community[] {
  // 只在骨架边上跑，理由见 SEMANTIC_RELATIONS 的注释
  const data: GraphData = coreGraph(input)
  const labels = new Map<string, string>()
  for (const node of data.nodes) {
    labels.set(node.id, node.id)
  }
  const adjacency: Map<string, string[]> = buildAdjacency(data.edges)

  for (let iter = 0; iter < maxIterations; iter += 1) {
    let changed: boolean = false

    // 按 id 排序遍历：不同设备/不同运行得到一致结果
    const ordered: GraphNode[] = [...data.nodes].sort((a, b) => a.id.localeCompare(b.id))
    for (const node of ordered) {
      const neighbors: string[] = adjacency.get(node.id) ?? []
      if (neighbors.length === 0) {
        continue
      }

      const tally = new Map<string, number>()
      for (const neighbor of neighbors) {
        const label: string = labels.get(neighbor) ?? neighbor
        tally.set(label, (tally.get(label) ?? 0) + 1)
      }

      let bestLabel: string = labels.get(node.id) ?? node.id
      let bestCount: number = -1
      for (const [label, count] of tally.entries()) {
        if (count > bestCount || (count === bestCount && label < bestLabel)) {
          bestLabel = label
          bestCount = count
        }
      }

      if (bestLabel !== labels.get(node.id)) {
        labels.set(node.id, bestLabel)
        changed = true
      }
    }

    if (!changed) {
      break
    }
  }

  const groups = new Map<string, string[]>()
  for (const [nodeId, label] of labels.entries()) {
    const list: string[] = groups.get(label) ?? []
    list.push(nodeId)
    groups.set(label, list)
  }

  const byId = new Map<string, GraphNode>()
  for (const node of data.nodes) {
    byId.set(node.id, node)
  }

  const communities: Community[] = []
  for (const [label, nodeIds] of groups.entries()) {
    // 社区名取「成员里 PageRank 最高的那个节点的名字」——
    // 用 id 或编号做名字对用户没有意义
    const ranks: Map<string, number> = pageRank(
      { nodes: data.nodes, edges: data.edges },
      0.85,
      10
    )
    // 取「实体节点」里 PageRank 最高的做名字。城市/时代/类型是抽象节点，
    // 拿「仰韶」当社区名不如拿「仰韶村遗址」—— 后者用户能点进去看
    const ABSTRACT_TYPES: readonly string[] = ['City', 'Era', 'Type']
    let topId: string = ''
    let topScore: number = -1
    for (const nodeId of nodeIds) {
      const node: GraphNode | undefined = byId.get(nodeId)
      if (node === undefined || ABSTRACT_TYPES.includes(node.type)) {
        continue
      }
      const score: number = ranks.get(nodeId) ?? 0
      if (score > topScore) {
        topScore = score
        topId = nodeId
      }
    }
    if (topId.length === 0) {
      topId = label
    }
    const topNode: GraphNode | undefined = byId.get(topId)
    communities.push({
      id: label,
      name: topNode !== undefined ? topNode.name : label,
      nodeIds,
      size: nodeIds.length,
    })
  }

  communities.sort((a, b) => b.size - a.size)
  return communities
}

/**
 * BFS 最短路（返回最多 `limit` 条可达路径）。
 *
 * 用 BFS 而不是 Dijkstra：本图谱的边没有真实「距离」语义，权重只表示关联强弱，
 * 用它当距离会让结果反直觉（强关联反而"近"，但用户看不出为什么）。
 * 按跳数最短更符合「隔了几层关系」的直觉。
 */
export function findPaths(
  data: GraphData,
  from: string,
  to: string,
  limit: number = 3
): GraphPathChain[] {
  if (from === to) {
    return []
  }
  const adjacency: Map<string, string[]> = buildAdjacency(data.edges)
  const byId = new Map<string, GraphNode>()
  for (const node of data.nodes) {
    byId.set(node.id, node)
  }
  const edgeRel = new Map<string, string>()
  for (const edge of data.edges) {
    edgeRel.set(`${edge.from}->${edge.to}`, edge.rel)
    edgeRel.set(`${edge.to}->${edge.from}`, edge.rel)
  }

  const results: GraphPathChain[] = []
  // 队列里存的是「从起点到当前节点的路径」
  const queue: string[][] = [[from]]

  while (queue.length > 0 && results.length < limit) {
    const path: string[] = queue.shift() ?? []
    const last: string = path[path.length - 1] ?? ''
    if (last === to) {
      results.push(toChain(path, byId, edgeRel))
      continue
    }
    if (path.length > 5) {
      continue
    }
    for (const neighbor of adjacency.get(last) ?? []) {
      if (!path.includes(neighbor)) {
        queue.push([...path, neighbor])
      }
    }
  }

  return results
}

function toChain(
  path: readonly string[],
  byId: Map<string, GraphNode>,
  edgeRel: Map<string, string>
): GraphPathChain {
  const chain: GraphPathChain = []
  for (let i = 0; i < path.length - 1; i += 1) {
    const a: string = path[i] ?? ''
    const b: string = path[i + 1] ?? ''
    chain.push({
      from: a,
      fromName: byId.get(a)?.name ?? a,
      rel: (edgeRel.get(`${a}->${b}`) ?? 'related') as GraphPathChain[number]['rel'],
      to: b,
      toName: byId.get(b)?.name ?? b,
    })
  }
  return chain
}
