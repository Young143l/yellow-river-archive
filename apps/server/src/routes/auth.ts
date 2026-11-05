/**
 * 账号路由。
 *
 * 一个端点同时承担注册与登录：用户名不存在即注册，存在即验 PIN。
 * 与客户端「未注册就直接注册，不用做太复杂」的产品决策对应。
 */

import type { FastifyInstance } from 'fastify'
import type { Db } from '../db/index'
import { createAccount, validatePin, validateUsername, verifyAccount, type AccountResult } from '../auth/store'

export function registerAuthRoutes(app: FastifyInstance, db: Db): void {
  app.post<{ Body: { username?: string; pin?: string } }>('/api/auth', async (request, reply) => {
    const username: string = (request.body?.username ?? '').trim()
    const pin: string = (request.body?.pin ?? '').trim()

    const nameError: string | null = validateUsername(username)
    if (nameError !== null) {
      return reply.code(400).send({ ok: false, message: nameError })
    }
    const pinError: string | null = validatePin(pin)
    if (pinError !== null) {
      return reply.code(400).send({ ok: false, message: pinError })
    }

    try {
      const existing: AccountResult | null = verifyAccount(db, username, pin)
      if (existing !== null) {
        return { ok: true, userId: existing.userId, username: existing.username, created: false }
      }
      // 走到这里要么是新人，要么是老用户 PIN 输错。先查占用再决定
      const taken: { id: string } | undefined = db
        .prepare('SELECT id FROM accounts WHERE username = ? COLLATE NOCASE')
        .get(username) as { id: string } | undefined
      if (taken !== undefined) {
        return reply.code(401).send({ ok: false, message: '这个名字已被使用，PIN 不对' })
      }
      const created = createAccount(db, username, pin)
      return { ok: true, userId: created.userId, username: created.username, created: true }
    } catch (err) {
      return reply.code(409).send({ ok: false, message: (err as Error).message })
    }
  })
}
