/**
 * 设备登记（同步中心展示「已连接设备」用）。
 *
 * 这里原来还放着配对码的创建与兑换。ADR-044 之后账号是唯一云端身份，
 * 配对码两端点已退役，只留下这两个还在被 /api/sync 使用的函数。
 * 文件因此从 pairing.ts 改名为 devices.ts。
 */

import type { Db } from '../db/index'

/** 登记设备（首次见到就插入，之后再见到只刷新 last_seen） */
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
