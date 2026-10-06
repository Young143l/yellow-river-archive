/**
 * 问答客户端（服务端 RAG 通道）。
 *
 * 与 CloudSync 的区别：这是**请求-响应**式的短连接，一次问答建一次连、
 * 收完 done 就关。不常驻的理由是：问答是低频操作（用户想好了才问），
 * 常驻连接会白白占用软总线与电量；而同步是随时可能被对端触发的，才需要常驻。
 *
 * 断网时的行为：连接失败 → 回调 onError，由页面提示「AI 不可用，
 * 可改用本地检索」。这里**不做端侧生成** —— 端侧没有模型（ADR-004）。
 */

import { webSocket } from '@kit.NetworkKit'
import { common } from '@kit.AbilityKit'
import { hilog } from '@kit.PerformanceAnalysisKit'

import type { Citation, GraphPath } from '../shared'
import type { QaTurn } from '../model/QaTurn'
import { DEFAULT_BASE_URL } from './sync/SyncService'
import { PersonalDao } from './PersonalDao'

interface ServerMessage {
  readonly type: string
  readonly text?: string
  readonly answer?: string
  readonly citations?: Citation[]
  readonly graphPaths?: GraphPath[]
  readonly degraded?: boolean
  readonly message?: string
}

export class QaClient {
  /**
   * 提问一次。
   *
   * 整体不抛异常：任何失败都走 onError，因为问答页不该因为网络问题崩掉。
   */
  static async ask(context: common.Context, query: string, turn: QaTurn): Promise<boolean> {
    let baseUrl: string = await PersonalDao.getSyncMeta(context, 'syncBaseUrl')
    if (baseUrl.length === 0) {
      baseUrl = DEFAULT_BASE_URL
    }
    const wsUrl: string = baseUrl.startsWith('https://')
      ? `wss://${baseUrl.slice('https://'.length)}`
      : baseUrl.startsWith('http://')
        ? `ws://${baseUrl.slice('http://'.length)}`
        : baseUrl

    const sessionId: string = `${new Date().getTime()}`
    let finished: boolean = false

    try {
      const socket: webSocket.WebSocket = webSocket.createWebSocket()

      socket.on('message', (err: Object, value: string | ArrayBuffer) => {
        if (typeof value !== 'string') {
          return
        }
        let message: ServerMessage
        try {
          message = JSON.parse(value) as ServerMessage
        } catch (parseErr) {
          return
        }

        if (message.type === 'ack') {
          // ack 只表示服务端已收到，pending 已经在转圈，不需要额外处理
        } else if (message.type === 'delta') {
          turn.answer += message.text !== undefined ? message.text : ''
        } else if (message.type === 'done') {
          finished = true
          turn.answer = message.answer !== undefined ? message.answer : turn.answer
          turn.citations = message.citations !== undefined ? message.citations : []
          turn.graphPaths = message.graphPaths !== undefined ? message.graphPaths : []
          turn.degraded = message.degraded === true
          turn.pending = false
          socket.close()
        } else if (message.type === 'error') {
          finished = true
          turn.error = message.message !== undefined ? message.message : '问答服务返回错误'
          turn.pending = false
          socket.close()
        }
      })

      socket.on('error', () => {
        if (!finished) {
          finished = true
          turn.error = '无法连接问答服务。可改用本地检索，或检查网络。'
          turn.pending = false
        }
      })

      hilog.info(0x0000, 'qaDiag', '连接中：%{public}s', wsUrl)
      await socket.connect(`${wsUrl}/api/qa`)
      hilog.info(0x0000, 'qaDiag', '已连接，准备发送')
      const sent: boolean = await socket.send(
        JSON.stringify({ type: 'ask', sessionId: sessionId, query: query })
      )
      hilog.info(0x0000, 'qaDiag', '发送结果=%{public}s', `${sent}`)

      // 等待收尾（done / error / 超时）。轮询而非事件，够简单也够稳
      const deadline: number = new Date().getTime() + 90_000
      while (!finished && new Date().getTime() < deadline) {
        await QaClient.sleep(120)
      }
      if (!finished) {
        turn.error = '回答超时，请重试'
        turn.pending = false
        await socket.close()
      }
      return true
    } catch (err) {
      turn.error = '无法连接问答服务，请检查网络后重试'
      turn.pending = false
      return false
    }
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout(() => {
        resolve()
      }, ms)
    })
  }
}
