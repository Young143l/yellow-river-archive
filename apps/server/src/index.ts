/**
 * 服务入口。
 *
 * 定位（ADR-009）：只做两件事 —— 个人数据云存储（D4）与 RAG 检索问答（D3）。
 * 不掌管档案内容，不参与端侧基础功能闭环。
 */

import { buildServer } from './app'
import { readServerConfig } from './config'

async function main(): Promise<void> {
  const config = readServerConfig()
  const app = await buildServer({ config })

  for (const signal of ['SIGINT', 'SIGTERM'] as const) {
    process.on(signal, () => {
      void app.close().then(() => {
        process.exit(0)
      })
    })
  }

  await app.listen({ host: config.host, port: config.port })
}

main().catch((err: unknown) => {
  console.error('[server] 启动失败：', err instanceof Error ? err.message : err)
  process.exit(1)
})
