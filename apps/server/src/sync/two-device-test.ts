/**
 * 双设备同步协议验证。
 *
 * 为什么能用两个 Node 客户端代替两台真机：云端通道是**设备无关**的 ——
 * 它只认 `userId + deviceId`，不关心对端是鸿蒙设备还是 Node 进程。
 * 因此协议正确性（LWW 收敛、变更日志、冲突记录、不回声广播）可以完整验证，
 * 不需要第二台物理设备。
 *
 * 这解决的是看板 B1 的一部分：**协议层面**已验证；
 * 剩下的「分布式软总线跨设备」属于通道 A，仍需真机对真机。
 *
 * 运行：先启动服务（pnpm server），再执行 pnpm sync:test
 */

import { WebSocket } from 'ws'

const BASE: string = process.env.SYNC_TEST_BASE ?? 'http://127.0.0.1:8787'
const WS_BASE: string = BASE.replace('http', 'ws')

// ---------------------------------------------------------------------------
// 断言与统计
// ---------------------------------------------------------------------------

let passed: number = 0
let failed: number = 0

function check(name: string, ok: boolean, detail: string): void {
  if (ok) {
    passed += 1
    console.log(`  PASS  ${name} —— ${detail}`)
  } else {
    failed += 1
    console.log(`  FAIL  ${name} —— ${detail}`)
  }
}

// ---------------------------------------------------------------------------
// 测试客户端：模拟一台设备
// ---------------------------------------------------------------------------

interface SyncableRecord {
  readonly id: string
  readonly updatedAt: number
  readonly createdAt: number
  readonly deviceId: string
  readonly deleted: boolean
}

interface ChangeSet {
  readonly table: string
  readonly records: readonly SyncableRecord[]
}

/** 一台模拟设备：持有 WS 连接与自己的同步游标 */
class FakeDevice {
  readonly id: string
  readonly name: string
  readonly userId: string
  cursor: number = 0
  readonly inbox: Record<string, unknown>[] = []

  private readonly socket: WebSocket

  constructor(userId: string, deviceId: string, name: string, socket: WebSocket) {
    this.userId = userId
    this.id = deviceId
    this.name = name
    this.socket = socket
  }

  static async connect(userId: string, deviceId: string, name: string): Promise<FakeDevice> {
    const url: string = `${WS_BASE}/api/sync?userId=${encodeURIComponent(userId)}&deviceId=${deviceId}&deviceName=${encodeURIComponent(name)}`
    const socket = new WebSocket(url)
    const device = new FakeDevice(userId, deviceId, name, socket)

    socket.on('message', (raw: Buffer) => {
      try {
        device.inbox.push(JSON.parse(raw.toString()) as Record<string, unknown>)
      } catch (err) {
        // 忽略解析失败
      }
    })

    await new Promise<void>((resolve, reject) => {
      socket.once('open', () => resolve())
      socket.once('error', (err: Error) => reject(err))
    })
    // 等首帧 state 消息
    await device.waitFor('state')
    return device
  }

  send(message: object): void {
    this.socket.send(JSON.stringify(message))
  }

  /** 等某类消息出现（或超时） */
  async waitFor(type: string, timeoutMs: number = 4000): Promise<Record<string, unknown> | undefined> {
    const deadline: number = Date.now() + timeoutMs
    while (Date.now() < deadline) {
      const found = this.inbox.find((m) => m.type === type)
      if (found !== undefined) {
        return found
      }
      await sleep(30)
    }
    return undefined
  }

  /** 取并清空收件箱里某类消息（避免上次的残留影响本次判断） */
  drain(): Record<string, unknown>[] {
    const all = [...this.inbox]
    this.inbox.length = 0
    return all
  }

  async push(changes: ChangeSet[]): Promise<Record<string, unknown> | undefined> {
    this.drain()
    this.send({ type: 'push', deviceId: this.id, changes })
    return this.waitFor('applied')
  }

  async pull(since: number): Promise<Record<string, unknown> | undefined> {
    this.drain()
    this.send({ type: 'pull', deviceId: this.id, since })
    const result = await this.waitFor('pulled')
    if (result !== undefined) {
      const cursor: number = result.cursor as number
      if (typeof cursor === 'number') {
        this.cursor = cursor
      }
    }
    return result
  }

  close(): void {
    this.socket.close()
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

async function post<T>(path: string, body: object): Promise<T> {
  const response = await fetch(`${BASE}${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  })
  return (await response.json()) as T
}

/** 从 pulled 消息里提取某条记录 */
function findRecord(message: Record<string, unknown> | undefined, recordId: string): SyncableRecord | undefined {
  if (message === undefined) {
    return undefined
  }
  const changes = message.changes as ChangeSet[] | undefined
  if (changes === undefined) {
    return undefined
  }
  for (const set of changes) {
    for (const record of set.records) {
      if (record.id === recordId) {
        return record
      }
    }
  }
  return undefined
}

// ---------------------------------------------------------------------------
// 主流程
// ---------------------------------------------------------------------------

async function main(): Promise<void> {
  console.log('=== 双设备同步协议验证 ===\n')

  // ---- 1. 配对码绑定同一身份 ----
  console.log('[1] 身份绑定（配对码兜底路径）')
  const pairing = await post<{ code: string; userId: string; expiresAt: number }>('/api/sync/pair', {})
  check('设备 A 生成配对码', /^\d{6}$/.test(pairing.code), `code=${pairing.code} userId=${pairing.userId}`)

  const joined = await post<{ ok: boolean; userId: string; code: string; message: string }>(
    '/api/sync/pair/join',
    { code: pairing.code, deviceId: 'device-B', deviceName: '模拟设备B' }
  )
  check(
    '设备 B 用配对码加入，得到同一 userId',
    joined.ok && joined.userId === pairing.userId,
    `${joined.message}，两端 userId 一致=${joined.userId === pairing.userId}`
  )

  // 配对码是一次性的
  const reuseResponse = await fetch(`${BASE}/api/sync/pair/join`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ code: pairing.code, deviceId: 'device-C' }),
  })
  const reuse = (await reuseResponse.json()) as { code?: string; message?: string }
  check(
    '配对码一次性（重放被拒）',
    reuseResponse.status === 400,
    `HTTP ${reuseResponse.status} ${reuse.message ?? ''}`
  )

  // ---- 2. 建连 ----
  console.log('\n[2] 建立同步连接')
  const deviceA = await FakeDevice.connect(pairing.userId, 'device-A', '模拟设备A')
  const deviceB = await FakeDevice.connect(pairing.userId, 'device-B', '模拟设备B')
  // 必须验证真的收到了 state 帧 —— 只看 cursor 是无意义的（它初值就是 0）
  const aState = deviceA.drain().find((m) => m.type === 'state')
  const bState = deviceB.drain().find((m) => m.type === 'state')
  check(
    '两端建连并收到初始 state',
    aState !== undefined && bState !== undefined,
    `state 帧已收到，含服务器游标`
  )

  // ---- 3. 单向推送与拉取 ----
  console.log('\n[3] 单向推送 → 对端拉取')
  const favTime: number = Date.now()
  const fav: SyncableRecord & { targetType: string; targetId: string; tagIds: string[] } = {
    id: 'site:ly-erlitou',
    updatedAt: favTime,
    createdAt: favTime,
    deviceId: 'device-A',
    deleted: false,
    targetType: 'site',
    targetId: 'ly-erlitou',
    tagIds: [],
  }
  const appliedA = await deviceA.push([{ table: 'favorites', records: [fav] }])
  check(
    '设备 A 推送被接受',
    appliedA !== undefined && (appliedA.applied as number) === 1,
    `applied=${appliedA?.applied}`
  )

  // 设备 B 应收到广播（服务端存权威版本后主动推给同用户其他设备）
  const broadcastMsg = await deviceB.waitFor('pulled')
  const broadcastRecord = findRecord(broadcastMsg, fav.id)
  check(
    '设备 B 收到实时广播',
    broadcastRecord !== undefined && broadcastRecord.updatedAt === favTime,
    `无需轮询即收到，updatedAt 一致=${broadcastRecord?.updatedAt === favTime}`
  )

  // 设备 A 自己不应收到回声
  const aEcho = deviceA.drain().filter((m) => m.type === 'pulled')
  check('推送端不收到回声', aEcho.length === 0, `设备 A 未收到自己推送的回声`)

  // ---- 4. 游标拉取 ----
  console.log('\n[4] 游标语义')
  // 广播只是优化手段，**不推进游标** —— 若推进，丢一次广播就会永久漏掉那批变更。
  // 游标只由显式 pull 推进，代价是广播过的变更可能被重复下发（LWW 下幂等，无害）。
  await deviceB.pull(deviceB.cursor)
  const cursorBefore: number = deviceB.cursor
  const pullEmpty = await deviceB.pull(cursorBefore)
  check(
    '游标之后无变更时返回空',
    pullEmpty !== undefined && (pullEmpty.changes as ChangeSet[]).length === 0,
    `changes 为空`
  )

  const second: SyncableRecord = {
    id: 'site:zz-gongyi-yao',
    updatedAt: Date.now(),
    createdAt: Date.now(),
    deviceId: 'device-A',
    deleted: false,
  }
  await deviceA.push([{ table: 'favorites', records: [second] }])
  await sleep(120)
  const pulledSecond = await deviceB.pull(cursorBefore)
  check(
    '游标之后的新变更可被拉到',
    findRecord(pulledSecond, second.id) !== undefined,
    `cursor ${cursorBefore} → ${deviceB.cursor}`
  )

  // 重复拉取应为空（游标已推进）
  const repeat = await deviceB.pull(deviceB.cursor)
  check(
    '重复拉取为空（游标严格单调）',
    repeat !== undefined && (repeat.changes as ChangeSet[]).length === 0,
    '未重复下发'
  )

  // ---- 5. LWW 冲突裁决 ----
  console.log('\n[5] LWW 冲突裁决')
  const conflictTime: number = Date.now() + 10000
  const older: SyncableRecord = {
    id: 'site:conflict-target',
    updatedAt: conflictTime,
    createdAt: conflictTime,
    deviceId: 'device-A',
    deleted: false,
  }
  await deviceA.push([{ table: 'favorites', records: [older] }])
  await sleep(120)

  // 设备 B 推一个更早的时间戳：应被拒绝（服务端版本更新）
  const olderVersion: SyncableRecord = { ...older, updatedAt: conflictTime - 5000, deviceId: 'device-B' }
  const appliedOlder = await deviceB.push([{ table: 'favorites', records: [olderVersion] }])
  check(
    '旧版本被拒绝（服务端保持权威）',
    appliedOlder !== undefined && (appliedOlder.applied as number) === 0,
    `applied=${appliedOlder?.applied} skipped=${appliedOlder?.skipped} 冲突=${(appliedOlder?.conflicts as unknown[])?.length ?? 0}`
  )

  // 设备 B 推更新的时间戳：应被接受
  const newerVersion: SyncableRecord = { ...older, updatedAt: conflictTime + 5000, deviceId: 'device-B' }
  const appliedNewer = await deviceB.push([{ table: 'favorites', records: [newerVersion] }])
  check(
    '新版本被接受',
    appliedNewer !== undefined && (appliedNewer.applied as number) === 1,
    `applied=${appliedNewer?.applied}`
  )

  // ---- 6. 同时间戳的确定性裁决 ----
  console.log('\n[6] 同时间戳兜底规则（防永久分叉）')
  const tieTime: number = conflictTime + 20000
  const tieLow: SyncableRecord = {
    id: 'site:tie-target',
    updatedAt: tieTime,
    createdAt: tieTime,
    deviceId: 'device-A',
    deleted: false,
  }
  const tieHigh: SyncableRecord = { ...tieLow, deviceId: 'device-Z' }

  await deviceA.push([{ table: 'favorites', records: [tieLow] }])
  await sleep(120)
  const tieResult = await deviceB.push([{ table: 'favorites', records: [tieHigh] }])
  check(
    '同时间戳时 deviceId 大者胜（确定性）',
    tieResult !== undefined && (tieResult.applied as number) === 1,
    `device-Z 覆盖 device-A：applied=${tieResult?.applied}`
  )

  // 反向：用 deviceId 小者推同一时间戳，应被拒绝
  const tieReverse = await deviceA.push([{ table: 'favorites', records: [tieLow] }])
  check(
    '反向推送同时间戳被拒（规则可交换）',
    tieReverse !== undefined && (tieReverse.applied as number) === 0,
    `device-A 无法覆盖 device-Z：applied=${tieReverse?.applied}`
  )

  // ---- 7. 软删同步 ----
  console.log('\n[7] 软删同步')
  const tombstone: SyncableRecord = {
    ...newerVersion,
    updatedAt: Date.now() + 60000,
    deleted: true,
  }
  await deviceB.push([{ table: 'favorites', records: [tombstone] }])
  await sleep(150)
  const deviceAPull = await deviceA.pull(0)
  const pulledTombstone = findRecord(deviceAPull, tombstone.id)
  check(
    '删除以墓碑形式传播',
    pulledTombstone !== undefined && pulledTombstone.deleted === true,
    `收到 deleted=true 的记录（而非记录消失）`
  )

  // ---- 8. 冲突日志 ----
  console.log('\n[8] 冲突记录')
  const devicesResp = await (await fetch(`${BASE}/api/sync/devices?userId=${encodeURIComponent(pairing.userId)}`)).json() as {
    devices: { deviceId: string }[]
    records: number
    conflicts: number
  }
  check(
    '冲突已记入服务端日志',
    devicesResp.conflicts > 0,
    `冲突 ${devicesResp.conflicts} 条，服务端记录 ${devicesResp.records} 条`
  )
  check(
    '两台设备已登记',
    devicesResp.devices.length === 2,
    `设备：${devicesResp.devices.map((d) => d.deviceId).join(', ')}`
  )

  deviceA.close()
  deviceB.close()
  await sleep(200)

  console.log(`\n=== 结果：${passed} 通过 / ${failed} 失败 ===`)
  process.exit(failed === 0 ? 0 : 1)
}

main().catch((err: unknown) => {
  console.error('测试异常：', err)
  process.exit(1)
})
