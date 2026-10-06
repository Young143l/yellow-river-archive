/**
 * 通道 A：鸿蒙分布式数据服务（distributedKVStore）—— **主路径**。
 *
 * 对应赛题主要功能第 3 项「基于鸿蒙分布式数据服务实现收藏与笔记的跨设备同步」，
 * 因此这条通道的代码必须完整、可自环运行，答辩时优先说明。
 *
 * 数据组织：**一条记录一个键**（`<table>:<id>`），而不是把整张表塞进一个键。
 * 理由是冲突粒度 —— 整表存一个键时，两端各改一条不同记录也会互相覆盖；
 * 按记录存键则只有真正冲突的那条才需要 LWW 裁决。
 *
 * 通道可用性：分布式软总线要求「同华为账号 + 同一超级终端信任环」。
 * 信任环里没有第二台设备时，`sync()` 会静默无效果（不报错），
 * 因此 `available()` 只表示「本地 KV 可用」，真正的对端状态看 `status().detail`。
 */

import { distributedDeviceManager } from '@kit.DistributedServiceKit'
import { distributedKVStore } from '@kit.ArkData'
import { common } from '@kit.AbilityKit'

import type { ChangeSet, SyncableRecord } from '../../shared'
import { Tables } from '../../model/Schema'
import type { ChannelStatus, ChangeListener, SyncAdapter } from './Types'

/** 存储桶名。换名会导致旧数据读不到，定死不动 */
const STORE_ID: string = 'yra_personal'
const BUNDLE_NAME: string = 'com.yellowriver.archive'

/** 各表的键前缀，与 Tables 一致 */
function keyPrefix(table: string): string {
  return `${table}:`
}

function splitKey(key: string): string[] {
  const idx: number = key.indexOf(':')
  if (idx < 0) {
    return [key, '']
  }
  return [key.slice(0, idx), key.slice(idx + 1)]
}

/**
 * 把 KV 里读到的值还原成对象文本。
 *
 * 注意 SDK 里存在两个不同的形状：`store.get()` 返回裸的联合类型，
 * 而 `entry.value`（Entry 里的）是 `Value` 接口（含 `type` 与 `value` 两个字段）。
 * 两者不能互相赋值，所以这里分开两个函数。
 */
function rawToString(value: Uint8Array | string | number | boolean): string {
  if (typeof value === 'string') {
    return value
  }
  // 别的类型理论上不会出现（我们只写字符串），返回空串让上层当作非法记录跳过
  return ''
}

function entryValueToString(value: distributedKVStore.Value): string {
  return rawToString(value.value)
}

export class DistributedSync implements SyncAdapter {
  readonly name: string = '分布式软总线'

  private kvManager: distributedKVStore.KVManager | undefined = undefined
  private store: distributedKVStore.SingleKVStore | undefined = undefined
  private listener: ChangeListener | undefined = undefined
  private deviceManager: distributedDeviceManager.DeviceManager | undefined = undefined

  /** 最近一次 syncComplete 回调里的对端数量（-1 表示尚未同步过） */
  private lastPeerCount: number = -1
  private lastSyncAt: number = 0

  /**
   * 取信任环内设备的 networkId 列表。
   *
   * 必须显式传 deviceIds：实测 API 26 下 `sync([])` 会被参数校验拒绝
   * （报 `params deviceIdList must be array`），空数组不再表示「广播给所有设备」。
   */
  private trustedNetworkIds(): string[] {
    try {
      if (this.deviceManager === undefined) {
        this.deviceManager = distributedDeviceManager.createDeviceManager(BUNDLE_NAME)
      }
      const devices: distributedDeviceManager.DeviceBasicInfo[] =
        this.deviceManager.getAvailableDeviceListSync()
      const ids: string[] = []
      for (const device of devices) {
        const networkId: string | undefined = device.networkId
        if (networkId !== undefined && networkId.length > 0) {
          ids.push(networkId)
        }
      }
      return ids
    } catch (err) {
      // 拿不到设备列表（信任环未建立 / 权限不足）不是错误，只是没有对端
      return []
    }
  }

  /** 打开存储（幂等）。失败时返回 undefined，由调用方决定降级 */
  private async open(context: common.Context): Promise<distributedKVStore.SingleKVStore | undefined> {
    if (this.store !== undefined) {
      return this.store
    }
    try {
      const config: distributedKVStore.KVManagerConfig = {
        context: context,
        bundleName: BUNDLE_NAME,
      }
      this.kvManager = distributedKVStore.createKVManager(config)

      const options: distributedKVStore.Options = {
        createIfMissing: true,
        encrypt: false,
        backup: false,
        // 关掉自动同步：同步时机由应用控制（用户点按 / 进入同步中心），
        // 自动同步会在后台反复唤醒软总线，耗电且不可控
        autoSync: false,
        kvStoreType: distributedKVStore.KVStoreType.SINGLE_VERSION,
        securityLevel: distributedKVStore.SecurityLevel.S1,
      }
      const store = await this.kvManager.getKVStore<distributedKVStore.SingleKVStore>(
        STORE_ID,
        options
      )
      this.store = store
      return store
    } catch (err) {
      this.store = undefined
      return undefined
    }
  }

  /** 绑定数据变化与同步完成回调（每台设备只绑一次） */
  private bindEvents(store: distributedKVStore.SingleKVStore): void {
    if (this.listenerBound) {
      return
    }
    this.listenerBound = true

    store.on('dataChange', distributedKVStore.SubscribeType.SUBSCRIBE_TYPE_ALL, () => {
      // 对端改了数据。这里只发信号，具体拉取交给上层 ——
      // 回调里做异步 IO 会拖慢数据服务线程
      const cb: ChangeListener | undefined = this.listener
      if (cb !== undefined) {
        cb.onChanges([])
      }
    })

    store.on('syncComplete', (results: Array<[string, number]>) => {
      this.lastPeerCount = results.length
      this.lastSyncAt = new Date().getTime()
    })
  }

  private listenerBound: boolean = false

  async available(): Promise<boolean> {
    return this.store !== undefined
  }

  /** 显式初始化（由同步中心在进入时调用，拿到 context） */
  async init(context: common.Context): Promise<boolean> {
    const store: distributedKVStore.SingleKVStore | undefined = await this.open(context)
    if (store === undefined) {
      return false
    }
    this.bindEvents(store)
    return true
  }

  /**
   * 推送变更。
   *
   * 写本地 KV 后触发一次 PUSH_PULL 同步：分布式 KV 的模型是「本地写入 → 手动同步」，
   * 不主动 sync 的话数据只留在本机。
   */
  async push(changes: ChangeSet[], deviceId: string): Promise<number> {
    const store: distributedKVStore.SingleKVStore | undefined = this.store
    if (store === undefined) {
      return 0
    }

    let written: number = 0
    for (const set of changes) {
      for (const record of set.records) {
        const key: string = `${set.table}:${record.id}`
        await store.put(key, JSON.stringify(record))
        written += 1
      }
    }

    if (written > 0) {
      this.syncNow(distributedKVStore.SyncMode.PUSH_ONLY)
    }
    return written
  }

  /** 有对端就同步；没有对端时什么也不做（不报错，上层照常继续） */
  private syncNow(mode: distributedKVStore.SyncMode): number {
    const store: distributedKVStore.SingleKVStore | undefined = this.store
    if (store === undefined) {
      return 0
    }
    const ids: string[] = this.trustedNetworkIds()
    if (ids.length === 0) {
      this.lastPeerCount = 0
      return 0
    }
    try {
      store.sync(ids, mode)
      return ids.length
    } catch (err) {
      return 0
    }
  }

  /**
   * 拉取游标之后的变更。
   *
   * 先 sync 一次把对端数据落到本地，再按前缀扫描各表。
   * 扫描而不是维护索引表：记录量在百级，遍历成本可以忽略，
   * 而索引表一旦与数据脱节就会漏拉，是更贵的错误。
   */
  async pull(since: number, deviceId: string): Promise<ChangeSet[]> {
    const store: distributedKVStore.SingleKVStore | undefined = this.store
    if (store === undefined) {
      return []
    }

    this.syncNow(distributedKVStore.SyncMode.PULL_ONLY)

    const sets: ChangeSet[] = []
    for (const table of [Tables.TAGS, Tables.FAVORITES, Tables.NOTES, Tables.THEMES, Tables.VISITS]) {
      const entries: distributedKVStore.Entry[] = await store.getEntries(keyPrefix(table))
      const records: SyncableRecord[] = []
      for (const entry of entries) {
        const text: string = entryValueToString(entry.value)
        if (text.length === 0) {
          continue
        }
        try {
          const parsed = JSON.parse(text) as SyncableRecord
          if (parsed.updatedAt > since) {
            records.push(parsed)
          }
        } catch (err) {
          // 单条损坏不影响整批拉取
          continue
        }
      }
      if (records.length > 0) {
        sets.push({ table, records })
      }
    }
    return sets
  }

  subscribe(listener: ChangeListener): void {
    this.listener = listener
  }

  unsubscribe(): void {
    this.listener = undefined
  }

  async status(): Promise<ChannelStatus> {
    if (this.store === undefined) {
      return { name: this.name, available: false, detail: '分布式数据服务未就绪' }
    }
    if (this.lastPeerCount < 0) {
      return { name: this.name, available: true, detail: '就绪，尚未与对端握手' }
    }
    if (this.lastPeerCount === 0) {
      return {
        name: this.name,
        available: true,
        detail: '本机可用，信任环内未发现其他设备（需同华为账号并加入超级终端）',
      }
    }
    return { name: this.name, available: true, detail: `已与 ${this.lastPeerCount} 台设备同步` }
  }

  /** 上次同步完成时间，供同步中心展示 */
  get lastSync(): number {
    return this.lastSyncAt
  }

  /** 诊断用：单键直读（返回原始文本，空串表示读不到） */
  async debugGet(table: string, id: string): Promise<string> {
    const store: distributedKVStore.SingleKVStore | undefined = this.store
    if (store === undefined) {
      return ''
    }
    try {
      const value: boolean | string | number | Uint8Array = await store.get(`${table}:${id}`)
      return rawToString(value)
    } catch (err) {
      return ''
    }
  }

  /** 诊断用：前缀扫描计数 */
  async debugCountPrefix(table: string): Promise<number> {
    const store: distributedKVStore.SingleKVStore | undefined = this.store
    if (store === undefined) {
      return 0
    }
    try {
      const entries: distributedKVStore.Entry[] = await store.getEntries(keyPrefix(table))
      return entries.length
    } catch (err) {
      return 0
    }
  }
}
