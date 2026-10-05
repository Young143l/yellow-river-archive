/**
 * 检索接口。
 *
 * 用 POST 而非 GET：筛选条件是多值数组，塞进 query string 需要序列化约定，
 * 而且中文关键词的 URL 编码在部分客户端上容易踩坑（实测 curl 直发中文会 400）。
 */

import type { FastifyInstance, FastifyPluginAsync } from 'fastify'

import type { ApiError, SearchRequest, SearchResponse } from '@yra/shared'

import type { SearchDeps } from '../search/service'
import { search } from '../search/service'

const MAX_QUERY_LENGTH: number = 200

export const searchRoutes: FastifyPluginAsync<SearchDeps> = async (
  app: FastifyInstance,
  deps: SearchDeps
) => {
  app.post<{ Body: SearchRequest }>('/api/search', async (request, reply) => {
    const body: SearchRequest | undefined = request.body
    if (body === undefined || typeof body.query !== 'string') {
      const err: ApiError = { code: 'E2001', message: '缺少 query 字段' }
      return reply.code(400).send(err)
    }

    const query: string = body.query.trim()
    if (query.length === 0) {
      const err: ApiError = { code: 'E2001', message: 'query 不能为空' }
      return reply.code(400).send(err)
    }
    if (query.length > MAX_QUERY_LENGTH) {
      const err: ApiError = {
        code: 'E2001',
        message: `query 长度不能超过 ${MAX_QUERY_LENGTH} 字`,
      }
      return reply.code(400).send(err)
    }

    const result: SearchResponse = search(deps, { ...body, query })
    return result
  })
}
