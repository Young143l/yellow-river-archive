/**
 * 身份配对（D4-8 的兜底路径，路演主力）。
 *
 * 主路径是华为账号 openid，但它依赖 AppGallery Connect 建应用与权限申请，
 * 个人开发者可用性未经验证 —— 因此必须有一条零依赖的备用路径。
 *
 * 配对码的定位：设备 A 生成 6 位码，设备 B 输入即绑定同一身份。
 * 现场 30 秒可演示，不需要账号、不需要网络配置、不需要 AGC。
 *
 * 安全边界（如实说明）：这是**演示级**方案。码有效期内任何人拿到都能绑定，
 * 没有设备指纹校验，也没有速率限制之外的防暴力措施。生产环境应改为
 * 「带签名的短时令牌 + 用户在已登录设备上确认」，本项目不做那么重，
 * 但接口形状留了余地。
 */

import type { Db } from '../db/index'

/** 配对码有效期：10 分钟够现场演示，又不会长期留一个可被猜中的码 */
export const CODE_TTL_MS: number = 10 * 60 * 1000

/** 纯数字 6 位，避免用户输入时的大小写与易混字符问题 */
const CODE_LENGTH: number = 6
const MAX_ATTEMPTS: number = 5

export interface PairingCreated {
  readonly code: string
  readonly userId: string
  readonly expiresAt: number
}

export interface PairingJoined {
  readonly ok: boolean
  readonly userId: string
  readonly code: string
  readonly message: string
}

function randomCode(): string {
  let code: string = ''
  for (let i = 0; i < CODE_LENGTH; i += 1) {
    code += String(Math.floor(Math.random() * 10))
  }
  return code
}

function randomUserId(): string {
  // 不用 uuid 依赖：时间戳 + 随机段已足够区分演示场景下的用户
  return `u_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 10)}`
}

/** 设备 A：创建配对码。若已传 userId 则复用它（同一用户再开一台设备） */
export function createPairing(db: Db, existingUserId: string): PairingCreated {
  const userId: string = existingUserId.length > 0 ? existingUserId : randomUserId()
  const now: number = Date.now()
  const expiresAt: number = now + CODE_TTL_MS

  // 重试避免撞码（6 位数字空间 100 万，演示规模下撞码概率极低，
  // 但已有的活码不能被覆盖，否则先创建的设备会凭空失效）
  let code: string = ''
  for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt += 1) {
    const candidate: string = randomCode()
    const taken = db
      .prepare('SELECT 1 FROM pairing_codes WHERE code = ? AND expires_at > ?')
      .get(candidate, now)
    if (taken === undefined) {
      code = candidate
      break
    }
  }
  if (code.length === 0) {
    throw new Error('生成配对码失败（连续撞码），请重试')
  }

  db.prepare(
    'INSERT INTO pairing_codes (code, user_id, created_at, expires_at) VALUES (?, ?, ?, ?)'
  ).run(code, userId, now, expiresAt)

  return { code, userId, expiresAt }
}

/** 设备 B：用配对码加入。码是一次性的，用过即废并记下使用方 */
export function joinPairing(db: Db, code: string, deviceId: string): PairingJoined {
  const now: number = Date.now()
  const row = db
    .prepare('SELECT code, user_id AS userId, expires_at AS expiresAt, used_by AS usedBy FROM pairing_codes WHERE code = ?')
    .get(code) as { code: string; userId: string; expiresAt: number; usedBy: string | null } | undefined

  if (row === undefined) {
    return { ok: false, userId: '', code, message: '配对码不存在' }
  }
  if (row.usedBy !== null && row.usedBy.length > 0) {
    return { ok: false, userId: '', code, message: '该配对码已被使用，请在原设备上重新生成' }
  }
  if (row.expiresAt < now) {
    return { ok: false, userId: '', code, message: '配对码已过期，请在原设备上重新生成' }
  }

  db.prepare('UPDATE pairing_codes SET used_by = ?, used_at = ? WHERE code = ?').run(
    deviceId,
    now,
    code
  )
  return { ok: true, userId: row.userId, code, message: '配对成功' }
}

/** 登记设备（用于同步中心展示「已连接设备」） */
export function touchDevice(db: Db, userId: string, deviceId: string, deviceName: string): void {
  const now: number = Date.now()
  db.prepare(
    `INSERT INTO sync_devices (user_id, device_id, device_name, first_seen, last_seen)
     VALUES (?, ?, ?, ?, ?)
     ON CONFLICT(user_id, device_id) DO UPDATE SET last_seen = ?, device_name = ?`
  ).run(userId, deviceId, deviceName, now, now, now, deviceName)
}

export interface KnownDevice {
  readonly deviceId: string
  readonly deviceName: string
  readonly firstSeen: number
  readonly lastSeen: number
}

export function listDevices(db: Db, userId: string): KnownDevice[] {
  const rows = db
    .prepare(
      `SELECT device_id AS deviceId, device_name AS deviceName,
              first_seen AS firstSeen, last_seen AS lastSeen
         FROM sync_devices WHERE user_id = ? ORDER BY last_seen DESC`
    )
    .all(userId) as unknown as KnownDevice[]
  return rows
}

/** 清理过期配对码（服务启动时调一次即可，演示规模不需要定时任务） */
export function purgeExpiredPairings(db: Db): number {
  const result = db.prepare('DELETE FROM pairing_codes WHERE expires_at < ?').run(Date.now())
  return Number(result.changes)
}
