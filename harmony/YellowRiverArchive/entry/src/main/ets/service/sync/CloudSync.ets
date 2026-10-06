/**
 * 通道 B：云端同步（WebSocket + 服务端变更日志）—— **兜底路径**。
 *
 * 定位纪律（设计文档 §8.1）：通道 A（鸿蒙分布式数据服务）是主路径，
 * 因为赛题把「基于鸿蒙分布式数据服务」写在主要功能里。本通道服务于
 * 「跨网络、路演第二设备、真机数量不足」这些软总线覆盖不到的场景，
 * 以及「云端存储」加分项。**答辩时不能把它说成主要方案。**
 *
 * 协议与看板 B1 的模拟验证一致（apps/server/src/sync/two-device-test.ts）：
 * 连接带 userId + deviceId → push/pull → 服务端权威裁决 → 广播给同用户其他设备。
 */

import { webSocket } from '@kit.NetworkKit'
import { common } from '@kit.AbilityKit'

import type { ChangeSet, ConflictRecord, SyncableRecord } from '../../shared'
import type { ChannelStatus, ChangeListener, SyncAdapter } from './Types'

/** 单次等待服务端响应的超时（毫秒） */
const RESPONSE_TIMEOUT_MS: number = 8000

/**
 * ArkTS 的异常对象不是标准 Error —— BusinessError 的形状是 {code, message, name}。
 * 直接 `err instanceof Error` 会判否，导致真正的错误码与信息被丢掉，
 * 只留下「连接失败」这种无用文案。
 */
interface BusinessErrorLike {
  readonly code?: number
  readonly message?: string
}

function describeError(err: Object): string {
  const e = err as BusinessErrorLike
  const code: string = e.code !== undefined ? `code=${e.code} ` : ''
  const message: string = e.message !== undefined ? e.message : '未知错误'
  return `${code}${message}`.slice(0, 160)
}

interface ServerMessage {
  readonly type: string
  readonly applied?: number
  readonly changes?: ChangeSet[]
  readonly conflicts?: ConflictRecord[]
  readonly cursor?: number
  readonly done?: number
  readonly total?: number
  readonly direction?: string
  readonly message?: string
}

export class CloudSync implements SyncAdapter {
  readonly name: string = '云端存储'

  private socket: webSocket.WebSocket | undefined = undefined
  private connected: boolean = false
  private lastError: string = ''

  private baseUrl: string = ''
  private userId: string = ''
  private deviceId: string = ''
  private deviceName: string = ''

  private listener: ChangeListener | undefined = undefined

  /** 最近一帧收到的服务端消息，供 sendAndWait 匹配响应 */
  private lastMessage: ServerMessage | undefined = undefined
  /** 进度回调（同步中心页画进度条用） */
  private progressHandler: ((done: number, total: number, direction: string) => void) | undefined = undefined

  /** 设置服务器地址。仿真环境与真机地址不同，由调用方决定 */
  setBaseUrl(url: string): void {
    this.baseUrl = url
  }

  get error(): string {
    return this.lastError
  }

  /** 设置进度回调 */
  onProgress(handler: (done: number, total: number, direction: string) => void): void {
    this.progressHandler = handler
  }

  /**
   * 把 HTTP base url 换成 WebSocket 协议。
   *
   * 不换的话会直接用 `http://...` 去连 WebSocket，报 BusinessError 2302001
   * 「Websocket url error」—— 错误文案不说「协议不对」，只说是 url 错，容易误判成地址写错。
   */
  private wsUrl(): string {
    if (this.baseUrl.startsWith('https://')) {
      return `wss://${this.baseUrl.slice('https://'.length)}`
    }
    if (this.baseUrl.startsWith('http://')) {
      return `ws://${this.baseUrl.slice('http://'.length)}`
    }
    return this.baseUrl
  }

  /** 连接（幂等）。失败返回 false，由上层决定降级 */
  async init(
    context: common.Context,
    userId: string,
    deviceId: string,
    deviceName: string
  ): Promise<boolean> {
    if (this.connected && this.userId === userId) {
      return true
    }
    void context

    if (this.baseUrl.length === 0) {
      this.lastError = '未配置服务器地址'
      return false
    }
    if (userId.length === 0) {
      this.lastError = '未绑定身份'
      return false
    }

    this.userId = userId
    this.deviceId = deviceId
    this.deviceName = deviceName

    const url: string = `${this.wsUrl()}/api/sync?userId=${encodeURIComponent(userId)}&deviceId=${encodeURIComponent(deviceId)}&deviceName=${encodeURIComponent(deviceName)}`

    try {
      const socket: webSocket.WebSocket = webSocket.createWebSocket()
      this.socket = socket

      socket.on('message', (err: Object, value: string | ArrayBuffer) => {
        if (typeof value !== 'string') {
          return
        }
        this.handleMessage(value)
      })

      socket.on('close', () => {
        this.connected = false
      })

      socket.on('error', () => {
        this.connected = false
        this.lastError = '连接异常'
      })

      await socket.connect(url)
      this.connected = true
      this.lastError = ''
      // 等服务器首帧 state（内含服务器游标），但不因它没到而判失败
      await this.waitFor('state', 3000)
      return true
    } catch (err) {
      this.connected = false
      this.lastError = `连接失败：${describeError(err)}`
      return false
    }
  }

  private handleMessage(raw: string): void {
    let message: ServerMessage
    try {
      message = JSON.parse(raw) as ServerMessage
    } catch (err) {
      return
    }
    this.lastMessage = message

    if (message.type === 'progress' && this.progressHandler !== undefined) {
      this.progressHandler(message.done ?? 0, message.total ?? 0, message.direction ?? '')
    }

    // 服务端主动广播的变更（对端推上来的）交给上层处理
    if (message.type === 'pulled' && this.listener !== undefined) {
      const changes: ChangeSet[] = message.changes ?? []
      if (changes.length > 0) {
        this.listener.onChanges(changes)
      }
    }

    if (message.type === 'error') {
      this.lastError = message.message ?? '服务端返回错误'
    }
  }

  /**
   * 取最近一帧消息。
   *
   * 用方法而不是直接读字段：直接把 `this.lastMessage = undefined` 赋值后再读，
   * TS 会把它窄化成 `undefined` 并不再放宽（它不知道回调里会重新赋值），
   * 后续的属性访问会报 never。走一层方法可以避开这个窄化。
   */
  private peek(): ServerMessage | undefined {
    return this.lastMessage
  }

  /** 等某一类型的消息出现（轮询，够简单也够稳） */
  private async waitFor(type: string, timeoutMs: number): Promise<ServerMessage | undefined> {
    this.lastMessage = undefined
    const deadline: number = new Date().getTime() + timeoutMs
    while (new Date().getTime() < deadline) {
      const current: ServerMessage | undefined = this.peek()
      if (current !== undefined && current.type === type) {
        return current
      }
      await sleep(25)
    }
    return undefined
  }

  async available(): Promise<boolean> {
    return this.connected
  }

  async push(changes: ChangeSet[], deviceId: string): Promise<number> {
    const socket: webSocket.WebSocket | undefined = this.socket
    if (socket === undefined || !this.connected) {
      return 0
    }
    let count: number = 0
    for (const set of changes) {
      count += set.records.length
    }
    if (count === 0) {
      return 0
    }

    try {
      await socket.send(
        JSON.stringify({ type: 'push', deviceId: deviceId, changes: changes })
      )
      const applied: ServerMessage | undefined = await this.waitFor('applied', RESPONSE_TIMEOUT_MS)
      if (applied === undefined) {
        this.lastError = '推送超时'
        return 0
      }
      return applied.applied ?? 0
    } catch (err) {
      this.lastError = `推送失败：${describeError(err)}`
      return 0
    }
  }

  async pull(since: number, deviceId: string): Promise<ChangeSet[]> {
    const socket: webSocket.WebSocket | undefined = this.socket
    if (socket === undefined || !this.connected) {
      return []
    }

    try {
      await socket.send(JSON.stringify({ type: 'pull', deviceId: deviceId, since: since }))
      const pulled: ServerMessage | undefined = await this.waitFor('pulled', RESPONSE_TIMEOUT_MS)
      if (pulled === undefined) {
        this.lastError = '拉取超时'
        return []
      }
      return pulled.changes ?? []
    } catch (err) {
      this.lastError = `拉取失败：${describeError(err)}`
      return []
    }
  }

  /** 从最近一帧 pulled 里取服务器游标 */
  takeCursor(): number {
    const current: ServerMessage | undefined = this.peek()
    return current?.cursor ?? 0
  }

  subscribe(listener: ChangeListener): void {
    this.listener = listener
  }

  unsubscribe(): void {
    this.listener = undefined
  }

  async status(): Promise<ChannelStatus> {
    if (this.connected) {
      return { name: this.name, available: true, detail: `已连接 ${this.baseUrl}` }
    }
    return {
      name: this.name,
      available: false,
      detail: this.lastError.length > 0 ? this.lastError : '未连接',
    }
  }

  async close(): Promise<void> {
    const socket: webSocket.WebSocket | undefined = this.socket
    this.socket = undefined
    this.connected = false
    if (socket !== undefined) {
      try {
        await socket.close()
      } catch (err) {
        // 关闭失败无需处理
      }
    }
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve) => {
    setTimeout(() => {
      resolve()
    }, ms)
  })
}
