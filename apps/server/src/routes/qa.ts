/**
 * 问答接口（WebSocket 流式）。
 *
 * 为什么用 WS 而不是 SSE：端侧 ArkTS 的 `@ohos.net.webSocket` 是一等公民，
 * 而 SSE 需要自己解析 `text/event-stream` 且没有现成 API。用 WS 两侧代码都更少。
 *
 * 协议：客户端发 `ask` → 服务端回 `ack` → 若干 `delta` → 一条 `done`。
 * `ack` 的作用是让客户端能立刻给出「已收到、正在思考」的反馈 ——
 * 检索+精排+首字生成有 300-800ms 的间隔，没有 ack 用户会以为卡住了。
 */

import type { FastifyInstance, FastifyPluginAsync } from 'fastify'
import websocket from '@fastify/websocket'

import type { QaAsk, QaClientMessage, QaDelta, QaDone, QaServerMessage } from '@yra/shared'
import type { WebSocket } from 'ws'

import type { QaDeps } from '../qa/service'
import { answerQuestion } from '../qa/service'

export type QaRouteOptions = QaDeps

export const qaRoutes: FastifyPluginAsync<QaRouteOptions> = async (
  app: FastifyInstance,
  deps: QaRouteOptions
) => {
  await app.register(websocket)

  app.get('/api/qa', { websocket: true }, (socket: WebSocket) => {
    let busy: boolean = false

    socket.on('message', (raw: Buffer) => {
      let message: QaClientMessage
      try {
        message = JSON.parse(raw.toString()) as QaClientMessage
      } catch (err) {
        socket.send(JSON.stringify({ type: 'error', code: 'E5001', message: '消息不是合法 JSON' }))
        return
      }

      if (message.type !== 'ask') {
        socket.send(JSON.stringify({ type: 'error', code: 'E5002', message: '未知消息类型' }))
        return
      }

      const ask: QaAsk = message
      const query: string = ask.query.trim()
      if (query.length === 0) {
        socket.send(JSON.stringify({ type: 'error', code: 'E5003', message: '问题不能为空' }))
        return
      }
      if (busy) {
        socket.send(
          JSON.stringify({ type: 'error', code: 'E5004', message: '上一条问题还在处理中' })
        )
        return
      }

      busy = true
      void handleAsk(socket, deps, ask, query).finally(() => {
        busy = false
      })
    })
  })
}

async function handleAsk(
  socket: WebSocket,
  deps: QaRouteOptions,
  ask: QaAsk,
  query: string
): Promise<void> {
  const send = (message: QaServerMessage): void => {
    if (socket.readyState === 1) {
      socket.send(JSON.stringify(message))
    }
  }

  // 立刻回执，让客户端能显示「正在思考」
  const ack = { type: 'ack' as const, sessionId: ask.sessionId }
  send(ack)

  try {
    for await (const event of answerQuestion(deps, query)) {
      if (event.kind === 'delta') {
        const delta: QaDelta = { type: 'delta', text: event.text }
        send(delta)
      } else {
        const done: QaDone = {
          type: 'done',
          answer: event.answer,
          citations: event.citations,
          graphPaths: event.graphPaths,
          degraded: event.degraded,
        }
        send(done)
      }
    }
  } catch (err) {
    // answerQuestion 内部已做降级，走到这里说明是意料外的错误，如实告知
    send({
      type: 'error',
      code: 'E5005',
      message: `问答失败：${err instanceof Error ? err.message.slice(0, 120) : '未知错误'}`,
    })
  }
}
