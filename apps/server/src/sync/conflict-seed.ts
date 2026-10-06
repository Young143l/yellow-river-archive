/**
 * 冲突播种工具。
 *
 * 用途：**绕开 UI 自动化**制造一个可控的冲突，用于验证端侧冲突列表的展示。
 *
 * 原理：LWW 的冲突只在「本机有较新版本、而拉到较旧版本」时才由端侧记录
 * （本地赢，远端被丢弃）。所以步骤是：
 *   1. 在设备上改一条记录（不立即同步）→ 本机持有较新时间戳
 *   2. 用本工具往服务端推同一条记录的**较旧**版本
 *   3. 设备同步 → 拉到旧版本 → 本地赢 → 端侧写入一条冲突记录
 *
 * 为什么需要它：走 UI 构造真实冲突要在两台设备上各做约 10 步操作，
 * 而模拟器的 ui layout 在页面滚动后会返回空 dump，坐标定位随之失效。
 * 直接构造数据比驱动 UI 可靠得多。
 *
 * 用法：
 *   pnpm sync:conflict -- --userId=<id> --target=<itemId> --ageMs=60000
 */

import { WebSocket } from 'ws'

const BASE: string = process.env.SYNC_TEST_BASE ?? 'http://127.0.0.1:8787'
const WS_BASE: string = BASE.replace('http', 'ws')

interface Args {
  readonly userId: string
  readonly target: string
  readonly ageMs: number
  readonly deleted: boolean
}

function parseArgs(): Args {
  const argv: string[] = process.argv.slice(2)
  const get = (name: string): string | undefined => {
    const hit = argv.find((a) => a.startsWith(`--${name}=`))
    return hit?.slice(name.length + 3)
  }
  const userId: string = get('userId') ?? ''
  const target: string = get('target') ?? ''
  const ageMs: number = Number.parseInt(get('ageMs') ?? '60000', 10)
  const deleted: boolean = get('deleted') === 'true'
  return { userId, target, ageMs: Number.isFinite(ageMs) ? ageMs : 60000, deleted }
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

async function main(): Promise<void> {
  const args: Args = parseArgs()
  if (args.userId.length === 0 || args.target.length === 0) {
    console.error('用法：pnpm sync:conflict -- --userId=<id> --target=<itemId> [--ageMs=60000] [--deleted=true]')
    process.exit(1)
  }

  const recordId: string = `site:${args.target}`
  const updatedAt: number = Date.now() - args.ageMs

  const url: string = `${WS_BASE}/api/sync?userId=${encodeURIComponent(args.userId)}&deviceId=seed-device&deviceName=%E5%86%B2%E7%AA%81%E6%92%AD%E7%A7%8D`
  const socket = new WebSocket(url)

  let applied: number | undefined = undefined
  let conflicts: number = 0

  socket.on('message', (raw: Buffer) => {
    try {
      const message = JSON.parse(raw.toString()) as {
        type: string
        applied?: number
        conflicts?: unknown[]
      }
      if (message.type === 'applied') {
        applied = message.applied ?? 0
        conflicts = message.conflicts?.length ?? 0
      }
    } catch (err) {
      // 忽略
    }
  })

  await new Promise<void>((resolve, reject) => {
    socket.once('open', () => resolve())
    socket.once('error', reject)
  })
  await sleep(300)

  console.log(`为设备播种一条「较旧」的收藏记录：`)
  console.log(`  userId   : ${args.userId}`)
  console.log(`  recordId : ${recordId}`)
  console.log(`  updatedAt: ${updatedAt}（比当前时间早 ${Math.round(args.ageMs / 1000)} 秒）`)

  socket.send(
    JSON.stringify({
      type: 'push',
      deviceId: 'seed-device',
      changes: [
        {
          table: 'favorites',
          records: [
            {
              id: recordId,
              targetType: 'site',
              targetId: args.target,
              tagIds: [],
              updatedAt,
              createdAt: updatedAt,
              deviceId: 'seed-device',
              deleted: args.deleted,
            },
          ],
        },
      ],
    })
  )

  await sleep(1500)
  socket.close()

  console.log('')
  console.log(`服务端应答：applied=${applied ?? '无应答'}，冲突=${conflicts}`)
  if (applied === 0) {
    console.log('注意：服务端拒绝了这条推送 —— 说明服务端已有更新的版本，')
    console.log('      端侧不会产生冲突记录（冲突只在「本地较新、远端较旧」时出现）。')
    console.log('      若端侧尚未修改该记录，请先在设备上改一次再重试。')
  } else {
    console.log('')
    console.log('下一步：在设备上点「立即同步」，然后看同步中心的冲突列表。')
    console.log('预期：本地版本较新 → 采用本机，并新增一条冲突记录。')
  }
}

main().catch((err: unknown) => {
  console.error('执行失败：', err)
  process.exit(1)
})
