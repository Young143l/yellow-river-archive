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

/**
 * 流式结果的**静态缓冲**。
 *
 * 为什么不用回调或 @Observed 对象把增量推给页面：
 * 实测在 ArkTS/ArkUI 上，把增量写进「页面持有的嵌套对象」或「@Observed 对象的
 * 字段」都不会触发重渲染 —— 消息确实到了（设备日志可见 81 条 `on message`），
 * 界面却一直停在 pending 态。原因与 ArkUI 对嵌套状态的观察粒度有关，
 * 试过 @Observed、@ObjectLink、@Builder 读 this 三种写法均无效。
 *
 * 因此改成：QaClient 只往这里写，页面用定时器读进**顶层的 @State 字段**。
 * 顶层 @State 的赋值是 ArkUI 一定能观察到的。
 * 代价是多了一个静态字段与一次轮询，换来的是行为确定。
 */
export class QaBus {
  static answer: string = ''
  static citations: Citation[] = []
  static graphPaths: GraphPath[] = []
  static degraded: boolean = false
  static error: string = ''
  static finished: boolean = true

  static reset(): void {
    QaBus.answer = ''
    QaBus.citations = []
    QaBus.graphPaths = []
    QaBus.degraded = false
    QaBus.error = ''
    QaBus.finished = false
  }
}

export class QaClient {
  /**
   * 提问一次。
   *
   * 整体不抛异常：任何失败都走 onError，因为问答页不该因为网络问题崩掉。
   */
  static async ask(context: common.Context, query: string): Promise<void> {
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
        // 入口日志：跨进程链路调试的第一要务是确定「消息到没到」。
        // 这条日志之前缺失，导致排查时无法区分「没收到」与「收到了没渲染」，
        // 白绕了渲染层的弯路。
        hilog.info(0x0000, 'qaDiag', 'on message: type=%{public}s', typeof value)
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
          QaBus.answer += message.text !== undefined ? message.text : ''
          hilog.info(0x0000, 'qaDiag', 'delta 累积=%{public}d', QaBus.answer.length)
        } else if (message.type === 'done') {
          finished = true
          QaBus.answer = message.answer !== undefined ? message.answer : QaBus.answer
          QaBus.citations = message.citations !== undefined ? message.citations : []
          QaBus.graphPaths = message.graphPaths !== undefined ? message.graphPaths : []
          QaBus.degraded = message.degraded === true
          QaBus.finished = true
          hilog.info(0x0000, 'qaDiag', 'done 最终=%{public}d 引用=%{public}d', QaBus.answer.length, QaBus.citations.length)
          socket.close()
        } else if (message.type === 'error') {
          finished = true
          QaBus.error = message.message !== undefined ? message.message : '问答服务返回错误'
          QaBus.finished = true
          socket.close()
        }
      })

      socket.on('error', () => {
        if (!finished) {
          finished = true
          QaBus.error = '无法连接问答服务。可改用本地检索，或检查网络。'
          QaBus.finished = true
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
        QaBus.error = '回答超时，请重试'
        QaBus.finished = true
        await socket.close()
      }
    } catch (err) {
      QaBus.error = '无法连接问答服务，请检查网络后重试'
      QaBus.finished = true
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
