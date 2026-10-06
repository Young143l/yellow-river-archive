/**
 * 图谱接口。
 *
 * 四个端点：子图展开、实体检索、路径探索、社区发现。
 * 数据全部来自服务端的 kg_nodes / kg_edges（构建期由流水线产出）。
 */

import type { FastifyInstance, FastifyPluginAsync } from 'fastify'

import type {
  ApiError,
  CommunitiesResponse,
  GraphEdge,
  GraphNode,
  GraphPathResponse,
  GraphSearchResponse,
  SubgraphResponse,
} from '@yra/shared'

import type { Db } from '../db/index'
import { detectCommunities, findPaths, pageRank, type GraphData } from '../graph/algorithms'

export interface GraphRouteOptions {
  readonly db: Db
}

const MAX_DEPTH: number = 2
const MAX_NODES: number = 300

interface NodeRow {
  readonly id: string
  readonly type: string
  readonly name: string
  readonly aliases: string
  readonly rank: number
}

interface EdgeRow {
  readonly id: string
  readonly src: string
  readonly dst: string
  readonly rel: string
  readonly weight: number
  readonly evidence: string
}

function toNode(row: NodeRow): GraphNode {
  return {
    id: row.id,
    type: row.type as GraphNode['type'],
    name: row.name,
    aliases: row.aliases.length > 0 ? row.aliases.split(' ') : [],
    rank: row.rank,
  }
}

function toEdge(row: EdgeRow): GraphEdge {
  return {
    id: row.id,
    from: row.src,
    to: row.dst,
    rel: row.rel as GraphEdge['rel'],
    weight: row.weight,
    ...(row.evidence.length > 0 ? { evidence: row.evidence } : {}),
  }
}

/** 读取全部图数据（服务于路径与社区这类需要全局视角的算法） */
function loadFullGraph(db: Db): GraphData {
  const nodeRows = db.prepare('SELECT id, type, name, aliases, rank FROM kg_nodes').all() as unknown as NodeRow[]
  const edgeRows = db
    .prepare('SELECT id, src, dst, rel, weight, evidence FROM kg_edges')
    .all() as unknown as EdgeRow[]
  return { nodes: nodeRows.map(toNode), edges: edgeRows.map(toEdge) }
}

export const graphRoutes: FastifyPluginAsync<GraphRouteOptions> = async (
  app: FastifyInstance,
  options: GraphRouteOptions
) => {
  const { db } = options

  /** 子图展开：以某节点为中心取 depth 跳邻域 */
  app.get<{ Querystring: { nodeId?: string; depth?: string } }>(
    '/api/graph/subgraph',
    async (request, reply) => {
      const rootId: string = (request.query.nodeId ?? '').trim()
      if (rootId.length === 0) {
        const e: ApiError = { code: 'E6001', message: '需要 nodeId' }
        return reply.code(400).send(e)
      }
      const rawDepth: string | undefined = request.query.depth
      const depth: number = rawDepth !== undefined ? Number.parseInt(rawDepth, 10) : 1
      const safeDepth: number = Number.isFinite(depth) && depth >= 1 && depth <= MAX_DEPTH ? depth : 1

      // ---- 逐层展开 ----
      const visited = new Set<string>([rootId])
      let frontier: string[] = [rootId]

      for (let level = 0; level < safeDepth; level += 1) {
        if (frontier.length === 0 || visited.size >= MAX_NODES) {
          break
        }
        const placeholders: string = frontier.map(() => '?').join(',')
        const rows = db
          .prepare(`SELECT id, src, dst FROM kg_edges WHERE src IN (${placeholders}) OR dst IN (${placeholders})`)
          .all(...frontier, ...frontier) as unknown as { id: string; src: string; dst: string }[]

        const next: string[] = []
        for (const row of rows) {
          for (const id of [row.src, row.dst]) {
            if (!visited.has(id) && visited.size < MAX_NODES) {
              visited.add(id)
              next.push(id)
            }
          }
        }
        frontier = next
      }

      const nodeIds: string[] = [...visited]
      const nodePlaceholders: string = nodeIds.map(() => '?').join(',')
      const nodeRows = db
        .prepare(
          `SELECT id, type, name, aliases, rank FROM kg_nodes WHERE id IN (${nodePlaceholders})`
        )
        .all(...nodeIds) as unknown as NodeRow[]

      // 只返回两端都在子图内的边 —— 否则可视化会出现指向画布外的悬空边
      const edgeRows = db
        .prepare(
          `SELECT id, src, dst, rel, weight, evidence FROM kg_edges
            WHERE src IN (${nodePlaceholders}) AND dst IN (${nodePlaceholders})`
        )
        .all(...nodeIds, ...nodeIds) as unknown as EdgeRow[]

      const result: SubgraphResponse = {
        nodes: nodeRows.map(toNode),
        edges: edgeRows.map(toEdge),
      }
      return result
    }
  )

  /** 实体检索：节点名与别名模糊匹配，用于搜索框自动补全 */
  app.get<{ Querystring: { q?: string; limit?: string } }>(
    '/api/graph/search',
    async (request, reply) => {
      const query: string = (request.query.q ?? '').trim()
      if (query.length === 0) {
        const e: ApiError = { code: 'E6001', message: '需要 q' }
        return reply.code(400).send(e)
      }
      const rawLimit: string | undefined = request.query.limit
      const limit: number = rawLimit !== undefined ? Number.parseInt(rawLimit, 10) : 20
      const safeLimit: number = Number.isFinite(limit) && limit > 0 && limit <= 50 ? limit : 20

      const rows = db
        .prepare(
          `SELECT id, type, name, aliases, rank FROM kg_nodes
            WHERE name LIKE ? OR aliases LIKE ?
            ORDER BY rank DESC LIMIT ?`
        )
        .all(`%${query}%`, `%${query}%`, safeLimit) as unknown as NodeRow[]

      const result: GraphSearchResponse = { nodes: rows.map(toNode) }
      return result
    }
  )

  /** 路径探索：两节点间按跳数最短的若干条路径 */
  app.get<{ Querystring: { from?: string; to?: string; limit?: string } }>(
    '/api/graph/path',
    async (request, reply) => {
      const from: string = (request.query.from ?? '').trim()
      const to: string = (request.query.to ?? '').trim()
      if (from.length === 0 || to.length === 0) {
        const e: ApiError = { code: 'E6001', message: '需要 from 与 to' }
        return reply.code(400).send(e)
      }
      const rawLimit: string | undefined = request.query.limit
      const limit: number = rawLimit !== undefined ? Number.parseInt(rawLimit, 10) : 3
      const safeLimit: number = Number.isFinite(limit) && limit > 0 && limit <= 10 ? limit : 3

      const graph: GraphData = loadFullGraph(db)
      const paths: GraphPathResponse = { paths: findPaths(graph, from, to, safeLimit) }
      return paths
    }
  )

  /** 社区发现：自动聚合出的文化主题 */
  app.get<{ Querystring: { minSize?: string } }>('/api/graph/communities', async (request) => {
    const rawMin: string | undefined = request.query.minSize
    const minSize: number = rawMin !== undefined ? Number.parseInt(rawMin, 10) : 2
    const safeMin: number = Number.isFinite(minSize) && minSize >= 1 ? minSize : 2

    const graph: GraphData = loadFullGraph(db)
    const all = detectCommunities(graph)
    const result: CommunitiesResponse = {
      communities: all.filter((c) => c.size >= safeMin),
    }
    return result
  })

  /** 节点权重：PageRank 结果，供可视化决定节点大小 */
  app.get('/api/graph/ranks', async () => {
    const graph: GraphData = loadFullGraph(db)
    const ranks: Map<string, number> = pageRank(graph)
    const entries = [...ranks.entries()].sort((a, b) => b[1] - a[1]).slice(0, 50)
    return {
      ranks: entries.map(([id, score]) => ({ id, score: Math.round(score * 1000000) / 1000000 })),
    }
  })
}
