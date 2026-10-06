/**
 * 用量统计接口。
 *
 * 面向运维与演示：路演前能确认「演示一轮大概花多少 token」，
 * 异常时能从 errorRate 第一时间发现外部服务出问题。
 */

import type { FastifyInstance, FastifyPluginAsync } from 'fastify'

import type { ApiError, UsageStatsEntry, UsageStatsResponse } from '@yra/shared'

import { summarizeUsage, type Db } from '../db/index'

export interface StatsRouteOptions {
  readonly db: Db
}

const DEFAULT_DAYS: number = 7
const MAX_DAYS: number = 90
const MS_PER_DAY: number = 24 * 60 * 60 * 1000

export const statsRoutes: FastifyPluginAsync<StatsRouteOptions> = async (
  app: FastifyInstance,
  options: StatsRouteOptions
) => {
  const { db } = options

  app.get<{ Querystring: { days?: string } }>('/api/stats/usage', async (request, reply) => {
    const rawDays: string | undefined = request.query.days
    const days: number = rawDays !== undefined ? Number.parseInt(rawDays, 10) : DEFAULT_DAYS
    if (!Number.isFinite(days) || days < 1 || days > MAX_DAYS) {
      const err: ApiError = { code: 'E3001', message: `days 必须在 1~${MAX_DAYS} 之间` }
      return reply.code(400).send(err)
    }

    const since: number = Date.now() - days * MS_PER_DAY
    const byOperation: UsageStatsEntry[] = summarizeUsage(db, since)

    let totalCalls: number = 0
    let totalTokens: number = 0
    let totalMs: number = 0
    let totalErrors: number = 0
    for (const entry of byOperation) {
      totalCalls += entry.callCount
      totalTokens += entry.tokens
      totalMs += entry.totalMs
      totalErrors += entry.errorCount
    }

    const result: UsageStatsResponse = {
      since,
      totalCalls,
      totalTokens,
      totalMs,
      errorRate: totalCalls === 0 ? 0 : Math.round((totalErrors / totalCalls) * 10000) / 10000,
      byOperation,
    }
    return result
  })
}
