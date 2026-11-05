/**
 * 自建账号存储。
 *
 * 为什么不用华为账号：@kit.AccountKit 只存在于 HMS SDK，OpenHarmony SDK 没有
 * 这个 kit，引用即让 default product 编译失败（ADR-001/043 的「不使用 HMS」约束）。
 * 自建账号也贴开源鸿蒙叙事：服务器是自己的，账号体系也自管。
 *
 * 设计取舍：
 *  - 登录成功 = 返回一个稳定的 userId。同步/备份/快照的既有链路全部吃 userId，
 *    不需要为账号改任何一条同步逻辑
 *  - PIN 只存 sha256(salt + pin)。盐随机生成，一条一盐
 *  - userId 格式沿用 pairing 的 a_ 前缀，与 u_（配对生成）区分来源
 */

import { createHash, randomBytes } from 'node:crypto'

import type { Db } from '../db/index'

export interface AccountResult {
  readonly userId: string
  readonly username: string
}

/** 用户名规则：2-20 字符，不含空白。展示时保留原样，比对时忽略大小写 */
export function validateUsername(username: string): string | null {
  const name: string = username.trim()
  if (name.length < 2 || name.length > 20) {
    return '用户名需要 2-20 个字符'
  }
  if (/\s/.test(name)) {
    return '用户名不能包含空格'
  }
  return null
}

/** PIN 规则：4-6 位数字 */
export function validatePin(pin: string): string | null {
  if (!/^\d{4,6}$/.test(pin)) {
    return 'PIN 需要 4-6 位数字'
  }
  return null
}

function hashPin(salt: string, pin: string): string {
  return createHash('sha256').update(`${salt}:${pin}`).digest('hex')
}

/** 注册。用户名已占用时抛错（调用方转成 409） */
export function createAccount(db: Db, username: string, pin: string): AccountResult {
  const name: string = username.trim()
  const taken: { id: string } | undefined = db
    .prepare('SELECT id FROM accounts WHERE username = ? COLLATE NOCASE')
    .get(name) as { id: string } | undefined
  if (taken !== undefined) {
    throw new Error('这个名字已被使用，请换一个或直接登录')
  }
  const id: string = `a_${randomBytes(4).toString('hex')}`
  const salt: string = randomBytes(8).toString('hex')
  const now: number = Date.now()
  db.prepare(
    'INSERT INTO accounts (id, username, pin_hash, pin_salt, created_at) VALUES (?, ?, ?, ?, ?)'
  ).run(id, name, hashPin(salt, pin), salt, now)
  return { userId: id, username: name }
}

/** 登录。凭据不匹配返回 null（调用方转成 401），不区分「没这个人」和「PIN 错」 */
export function verifyAccount(db: Db, username: string, pin: string): AccountResult | null {
  const name: string = username.trim()
  const row: { id: string; username: string; pin_hash: string; pin_salt: string } | undefined = db
    .prepare('SELECT id, username, pin_hash, pin_salt FROM accounts WHERE username = ? COLLATE NOCASE')
    .get(name) as { id: string; username: string; pin_hash: string; pin_salt: string } | undefined
  if (row === undefined) {
    return null
  }
  if (hashPin(row.pin_salt, pin) !== row.pin_hash) {
    return null
  }
  return { userId: row.id, username: row.username }
}
