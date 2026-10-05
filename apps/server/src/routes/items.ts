/**
 * 档案条目只读接口。
 *
 * 四个端点：列表（带筛选分页）、详情、关联推荐、图谱子图。
 * 全部是只读 —— 服务端不接收内容写入（内容由构建期流水线产出）。
 */

import type { FastifyInstance, FastifyPluginAsync } from 'fastify'

import type { ApiError, ItemDetailResponse, ItemListResponse, RelatedResponse } from '@yra/shared'

import type { Db } from '../db/index'
import { getItem, listItems, itemExists, relatedItems } from '../store/items'
import type { VectorStore } from '../search/vectors'

export interface ItemsRouteOptions {
  readonly db: Db
  readonly vectors: VectorStore
}

const MAX_PAGE_SIZE: number = 100

function badRequest(code: string, message: string): ApiError {
  return { code, message }
}

export const itemsRoutes: FastifyPluginAsync<ItemsRouteOptions> = async (
  app: FastifyInstance,
  options: ItemsRouteOptions
) => {
  const { db, vectors } = options

  app.get<{ Querystring: Record<string, string | undefined> }>(
    '/api/items',
    async (request, reply) => {
      const rawPage: string | undefined = request.query.page
      const rawSize: string | undefined = request.query.pageSize

      const page: number = rawPage !== undefined ? Number.parseInt(rawPage, 10) : 1
      const pageSize: number = rawSize !== undefined ? Number.parseInt(rawSize, 10) : 20

      if (!Number.isFinite(page) || page < 1) {
        return reply.code(400).send(badRequest('E1001', 'page 必须是不小于 1 的整数'))
      }
      if (!Number.isFinite(pageSize) || pageSize < 1 || pageSize > MAX_PAGE_SIZE) {
        return reply.code(400).send(badRequest('E1001', `pageSize 必须在 1~${MAX_PAGE_SIZE} 之间`))
      }

      const result: ItemListResponse = listItems(db, {
        ...(request.query.city !== undefined ? { city: request.query.city } : {}),
        ...(request.query.era !== undefined ? { era: request.query.era } : {}),
        ...(request.query.type !== undefined ? { type: request.query.type } : {}),
        page,
        pageSize,
      })
      return result
    }
  )

  app.get<{ Params: { id: string } }>('/api/items/:id', async (request, reply) => {
    const item: ItemDetailResponse | undefined = getItem(db, request.params.id)
    if (item === undefined) {
      return reply.code(404).send(badRequest('E1002', `条目不存在：${request.params.id}`))
    }
    return item
  })

  app.get<{ Params: { id: string }; Querystring: { limit?: string } }>(
    '/api/items/:id/related',
    async (request, reply) => {
      const { id } = request.params
      if (!itemExists(db, id)) {
        return reply.code(404).send(badRequest('E1002', `条目不存在：${id}`))
      }
      const rawLimit: string | undefined = request.query.limit
      const limit: number = rawLimit !== undefined ? Number.parseInt(rawLimit, 10) : 6
      if (!Number.isFinite(limit) || limit < 1 || limit > 20) {
        return reply.code(400).send(badRequest('E1001', 'limit 必须在 1~20 之间'))
      }
      const result: RelatedResponse = { itemId: id, related: relatedItems(db, vectors, id, limit) }
      return result
    }
  )

  // 图谱子图：以某条目为中心，取其直接相连的节点与连边
  app.get<{ Params: { id: string }; Querystring: { depth?: string } }>(
    '/api/items/:id/subgraph',
    async (request, reply) => {
      const { id } = request.params
      if (!itemExists(db, id)) {
        return reply.code(404).send(badRequest('E1002', `条目不存在：${id}`))
      }

      const edges = db
        .prepare(
          `SELECT id, src, dst, rel, weight, evidence
             FROM kg_edges
            WHERE src = ? OR dst = ?
            ORDER BY weight DESC
            LIMIT 80`
        )
        .all(id, id) as {
        id: string
        src: string
        dst: string
        rel: string
        weight: number
        evidence: string
      }[]

      const nodeIds = new Set<string>([id])
      for (const edge of edges) {
        nodeIds.add(edge.src)
        nodeIds.add(edge.dst)
      }

      const placeholders: string = [...nodeIds].map(() => '?').join(',')
      const nodes = db
        .prepare(
          `SELECT id, type, name, aliases, rank FROM kg_nodes WHERE id IN (${placeholders})`
        )
        .all(...nodeIds) as {
        id: string
        type: string
        name: string
        aliases: string
        rank: number
      }[]

      return {
        root: id,
        nodes: nodes.map((n) => ({
          id: n.id,
          type: n.type,
          name: n.name,
          aliases: n.aliases.length > 0 ? n.aliases.split(' ') : [],
          rank: n.rank,
        })),
        edges: edges.map((e) => ({
          id: e.id,
          from: e.src,
          to: e.dst,
          rel: e.rel,
          weight: e.weight,
          ...(e.evidence.length > 0 ? { evidence: e.evidence } : {}),
        })),
      }
    }
  )
}
