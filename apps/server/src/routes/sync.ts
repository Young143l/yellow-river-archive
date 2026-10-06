/**
 * 同步服务：WebSocket 通道 + 配对码接口。
 *
 * 为什么同步用 WS 而不是 HTTP：
 *   1. 推送是双向的 —— 设备 A 改了数据，设备 B 需要被及时通知，HTTP 只能轮询
 *   2. 握手时带上身份，后续每次推拉不必重复鉴权与建连
 *
 * 通道定位（ADR-009）：这是**兜底通道**。主路径是鸿蒙分布式数据服务，
 * 它在同账号信任环内可用时更快且不依赖服务器。云端通道的价值在于
 * 「跨网络、路演第二设备、真机数量不足」这些分布式软总线覆盖不到的场景。
 */

import type { FastifyInstance, FastifyPluginAsync } from 'fastify'
import websocket from '@fastify/websocket'

import type {
  ApiError,
  ChangeSet,
  MsgError,
  SyncClientMessage,
  SyncPull,
  SyncPush,
  SyncServerMessage,
} from '@yra/shared'
import type { WebSocket } from 'ws'

import type { Db } from '../db/index'
import {
  createPairing,
  joinPairing,
  listDevices,
  purgeExpiredPairings,
  touchDevice,
} from '../sync/pairing'
import { applyPull, applyPush, currentCursor, userStats } from '../sync/store'

export interface SyncRouteOptions {
  readonly db: Db
}

interface SyncConnectionQuery {
  readonly userId?: string
  readonly deviceId?: string
  readonly deviceName?: string
}

/** 同一用户的所有活跃连接，用于把变更广播给其他设备 */
const rooms = new Map<string, Set<WebSocket>>()

function joinRoom(userId: string, socket: WebSocket): void {
  const set: Set<WebSocket> = rooms.get(userId) ?? new Set<WebSocket>()
  set.add(socket)
  rooms.set(userId, set)
}

function leaveRoom(userId: string, socket: WebSocket): void {
  const set: Set<WebSocket> | undefined = rooms.get(userId)
  if (set === undefined) {
    return
  }
  set.delete(socket)
  if (set.size === 0) {
    rooms.delete(userId)
  }
}

/** 广播给同一用户的其他设备（不回声给来源设备，否则会造成回环推送） */
function broadcast(userId: string, from: WebSocket, message: SyncServerMessage): void {
  const set: Set<WebSocket> | undefined = rooms.get(userId)
  if (set === undefined) {
    return
  }
  const payload: string = JSON.stringify(message)
  for (const socket of set) {
    if (socket !== from && socket.readyState === 1) {
      socket.send(payload)
    }
  }
}

function errorMessage(code: string, message: string): MsgError {
  return { type: 'error', code, message }
}

export const syncRoutes: FastifyPluginAsync<SyncRouteOptions> = async (
  app: FastifyInstance,
  options: SyncRouteOptions
) => {
  const { db } = options

  const purged: number = purgeExpiredPairings(db)
  if (purged > 0) {
    app.log.info(`清理过期配对码 ${purged} 个`)
  }

  await app.register(websocket)

  // -------------------------------------------------------------------------
  // 配对码（REST，D4-8 兜底路径）
  // -------------------------------------------------------------------------

  app.post<{ Body: { userId?: string } }>('/api/sync/pair', async (request, reply) => {
    const existing: string = request.body?.userId ?? ''
    try {
      return createPairing(db, existing)
    } catch (err) {
      const e: ApiError = { code: 'E4001', message: (err as Error).message }
      return reply.code(500).send(e)
    }
  })

  app.post<{ Body: { code?: string; deviceId?: string; deviceName?: string } }>(
    '/api/sync/pair/join',
    async (request, reply) => {
      const code: string = (request.body?.code ?? '').trim()
      const deviceId: string = (request.body?.deviceId ?? '').trim()
      if (code.length === 0 || deviceId.length === 0) {
        const e: ApiError = { code: 'E4002', message: '需要 code 与 deviceId' }
        return reply.code(400).send(e)
      }
      const result = joinPairing(db, code, deviceId)
      if (!result.ok) {
        const e: ApiError = { code: 'E4003', message: result.message }
        return reply.code(400).send(e)
      }
      touchDevice(db, result.userId, deviceId, request.body?.deviceName ?? '')
      return result
    }
  )

  app.get<{ Querystring: { userId?: string } }>('/api/sync/devices', async (request, reply) => {
    const userId: string = request.query.userId ?? ''
    if (userId.length === 0) {
      const e: ApiError = { code: 'E4002', message: '需要 userId' }
      return reply.code(400).send(e)
    }
    return { userId, devices: listDevices(db, userId), ...userStats(db, userId) }
  })

  // -------------------------------------------------------------------------
  // 同步通道（WebSocket）
  // -------------------------------------------------------------------------

  app.get<{ Querystring: SyncConnectionQuery }>(
    '/api/sync',
    { websocket: true },
    (socket: WebSocket, request) => {
      const userId: string = (request.query.userId ?? '').trim()
      const deviceId: string = (request.query.deviceId ?? '').trim()
      const deviceName: string = (request.query.deviceName ?? '').trim()

      if (userId.length === 0 || deviceId.length === 0) {
        socket.send(JSON.stringify(errorMessage('E4002', '连接需要 userId 与 deviceId 参数')))
        socket.close()
        return
      }

      touchDevice(db, userId, deviceId, deviceName)
      joinRoom(userId, socket)
      app.log.info(`同步连接建立：user=${userId.slice(0, 12)}… device=${deviceId.slice(0, 8)}…`)

      // 建连即回报当前游标与状态，客户端据此决定是否需要拉取
      const initial: SyncServerMessage = {
        type: 'state',
        state: 'idle',
      }
      socket.send(
        JSON.stringify({
          ...initial,
          cursor: currentCursor(db, userId),
        })
      )

      socket.on('message', (raw: Buffer) => {
        let message: SyncClientMessage
        try {
          message = JSON.parse(raw.toString()) as SyncClientMessage
        } catch (err) {
          socket.send(JSON.stringify(errorMessage('E4004', '消息不是合法 JSON')))
          return
        }

        if (message.type === 'push') {
          handlePush(socket, message)
        } else if (message.type === 'pull') {
          handlePull(socket, message)
        } else {
          socket.send(JSON.stringify(errorMessage('E4005', `未知消息类型`)))
        }
      })

      socket.on('close', () => {
        leaveRoom(userId, socket)
      })

      socket.on('error', () => {
        leaveRoom(userId, socket)
      })

      // ---- 处理函数 ----

      function handlePush(socket: WebSocket, message: SyncPush): void {
        try {
          // 进度消息：先告知总量，客户端据此画进度条（对应赛题「清晰展示同步进度」）
          socket.send(
            JSON.stringify({
              type: 'progress',
              done: 0,
              total: countRecords(message.changes),
              direction: `${deviceName.length > 0 ? deviceName : deviceId.slice(0, 6)} → 云端`,
            })
          )

          const result = applyPush(db, userId, message.changes)
          socket.send(
            JSON.stringify({
              type: 'applied',
              applied: result.applied,
              conflicts: result.conflicts,
            })
          )

          // 服务端存的是权威版本，因此推来的变更也要广播给同用户的其他设备。
          // 不广播的话，三台设备两两同步的延迟会叠加。
          if (result.applied > 0) {
            broadcast(userId, socket, {
              type: 'pulled',
              changes: message.changes,
              conflicts: result.conflicts,
              cursor: currentCursor(db, userId),
              serverTime: Date.now(),
            } as SyncServerMessage)
          }
        } catch (err) {
          socket.send(
            JSON.stringify(errorMessage('E4006', `推送失败：${(err as Error).message.slice(0, 120)}`))
          )
        }
      }

      function handlePull(socket: WebSocket, message: SyncPull): void {
        try {
          const result = applyPull(db, userId, message.since, message.deviceId)
          socket.send(
            JSON.stringify({
              type: 'pulled',
              changes: result.changes,
              conflicts: result.conflicts,
              cursor: result.cursor,
              serverTime: Date.now(),
            })
          )
        } catch (err) {
          socket.send(
            JSON.stringify(errorMessage('E4007', `拉取失败：${(err as Error).message.slice(0, 120)}`))
          )
        }
      }
    }
  )
}

function countRecords(changes: readonly ChangeSet[]): number {
  let total: number = 0
  for (const set of changes) {
    total += set.records.length
  }
  return total
}
