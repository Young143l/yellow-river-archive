/**
 * 服务端配置。
 *
 * 与数据流水线共用仓库根目录的 .env（见 docs/env-template.md）。
 */

import { dirname, isAbsolute, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

import { loadEnv } from '@yra/ai'

/** 仓库根目录：所有相对路径都基于它解析，避免 pnpm --filter 切换工作目录后找不到文件 */
const HERE: string = dirname(fileURLToPath(import.meta.url))
const REPO_ROOT: string = resolve(HERE, '..', '..', '..')

function resolveFromRoot(p: string): string {
  return isAbsolute(p) ? p : resolve(REPO_ROOT, p)
}

export interface ServerConfig {
  readonly host: string
  readonly port: number
  readonly logLevel: string
  /** SQLite 数据库文件路径 */
  readonly dbPath: string
  /** 端侧预置包所在目录（服务端从这里导入数据，与端侧同源） */
  readonly presetDir: string
  /** 个人数据云存储目录（同步与备份，D4 使用） */
  readonly storageDir: string
  /** 仓库根目录 */
  readonly repoRoot: string
}

function optional(name: string, fallback: string): string {
  const value: string | undefined = process.env[name]
  return value !== undefined && value.length > 0 ? value : fallback
}

export function readServerConfig(): ServerConfig {
  loadEnv()
  return {
    host: optional('SERVER_HOST', '127.0.0.1'),
    port: Number.parseInt(optional('SERVER_PORT', '8787'), 10),
    logLevel: optional('LOG_LEVEL', 'info'),
    dbPath: resolveFromRoot(optional('DB_PATH', 'apps/server/data/yra.sqlite')),
    presetDir: resolveFromRoot(
      optional('PRESET_DIR', 'harmony/YellowRiverArchive/entry/src/main/resources/rawfile/data')
    ),
    storageDir: resolveFromRoot(optional('STORAGE_DIR', 'apps/server/data/storage')),
    repoRoot: REPO_ROOT,
  }
}
