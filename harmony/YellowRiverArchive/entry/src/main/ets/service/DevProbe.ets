import { common } from '@kit.AbilityKit'
import { distributedKVStore, relationalStore } from '@kit.ArkData'
import { BusinessError } from '@kit.BasicServicesKit'
import { resourceManager } from '@kit.LocalizationKit'

/**
 * 技术验证探针（D0-V）。
 *
 * 这个文件是**临时验证代码**：把关键技术在真机上跑一遍并记录结论，
 * 验证完成后可整体删除（结论会写进 docs/决策日志.md 的 ADR）。
 */

/** 单项验证结果 */
export class ProbeResult {
  readonly name: string
  readonly ok: boolean
  readonly detail: string
  readonly ms: number

  constructor(name: string, ok: boolean, detail: string, ms: number) {
    this.name = name
    this.ok = ok
    this.detail = detail
    this.ms = ms
  }
}

const STORE_ID: string = 'yra_probe_store'
const BUNDLE: string = 'com.yellowriver.archive'

function describeError(err: object): string {
  const e = err as BusinessError
  const code: number = e.code
  const msg: string = e.message
  return `[${code}] ${msg}`
}

/**
 * D0V-1：分布式键值库（distributedKVStore）可行性。
 *
 * 验证内容：
 *   1. KVManager 能否创建
 *   2. 协作型（DEVICE_COLLABORATION）存储能否打开
 *   3. 写入 / 读取 / 遍历 / 删除 是否正确
 *   4. 记录耗时，判断端侧个人数据的读写性能是否够用
 *
 * 说明：真正的"跨设备同步"需要第二台可信设备，单机只能验证 API 可用性与本地读写。
 */
export class DevProbe {
  static async probeDistributedKv(context: common.Context): Promise<ProbeResult> {
    const started: number = Date.now()
    const steps: string[] = []
    let store: distributedKVStore.SingleKVStore | undefined = undefined

    try {
      const config: distributedKVStore.KVManagerConfig = {
        bundleName: BUNDLE,
        context: context,
      }
      const manager: distributedKVStore.KVManager = distributedKVStore.createKVManager(config)
      steps.push('KVManager 创建成功')

      const options: distributedKVStore.Options = {
        createIfMissing: true,
        encrypt: false,
        backup: false,
        autoSync: true,
        kvStoreType: distributedKVStore.KVStoreType.DEVICE_COLLABORATION,
        securityLevel: distributedKVStore.SecurityLevel.S1,
      }
      store = await manager.getKVStore<distributedKVStore.SingleKVStore>(STORE_ID, options)
      steps.push('协作型存储已打开')

      // 写入
      const writeStart: number = Date.now()
      await store.put('probe:favorite:1', 'ly-erlitou')
      await store.put('probe:favorite:2', 'zz-shangcheng')
      await store.put('probe:note:1', '笔记内容')
      const writeMs: number = Date.now() - writeStart
      steps.push(`写入 3 条耗时 ${writeMs}ms`)

      // 读取
      const value: boolean | string | number | Uint8Array = await store.get('probe:favorite:1')
      const text: string = value as string
      if (text !== 'ly-erlitou') {
        return new ProbeResult('D0V-1 分布式键值库', false, `读取值不符：${text}`, Date.now() - started)
      }
      steps.push('读取校验通过')

      // 遍历
      const entries: distributedKVStore.Entry[] = await store.getEntries('probe:')
      steps.push(`前缀遍历得到 ${entries.length} 条`)
      if (entries.length < 3) {
        return new ProbeResult(
          'D0V-1 分布式键值库',
          false,
          `遍历条数不足：${entries.length}`,
          Date.now() - started
        )
      }

      // 删除
      await store.delete('probe:note:1')
      const afterDelete: distributedKVStore.Entry[] = await store.getEntries('probe:')
      if (afterDelete.length !== 2) {
        return new ProbeResult(
          'D0V-1 分布式键值库',
          false,
          `删除后条数异常：${afterDelete.length}`,
          Date.now() - started
        )
      }
      steps.push('删除校验通过')

      return new ProbeResult('D0V-1 分布式键值库', true, steps.join(' ｜ '), Date.now() - started)
    } catch (err) {
      const msg: string = describeError(err as object)
      return new ProbeResult('D0V-1 分布式键值库', false, `${msg} ｜ 已完成：${steps.join(' ｜ ')}`, Date.now() - started)
    }
  }

  /**
   * D0V-2：关系型存储（relationalStore / RDB）批量导入性能。
   *
   * 验证内容：首启导入到底会不会卡。以 1000 条 × 约 250 字的 chunk 为样本，
   * 模拟真实预置包导入（全量数据预计 80 条档案、约 1500 个 chunk）。
   *
   * 结论直接影响：是否需要导入进度条 / 分片导入 / 首启引导页。
   */
  static async probeRdb(context: common.Context): Promise<ProbeResult> {
    const started: number = Date.now()
    const steps: string[] = []

    try {
      const config: relationalStore.StoreConfig = {
        name: 'yra_probe.db',
        securityLevel: relationalStore.SecurityLevel.S1,
      }
      const store: relationalStore.RdbStore = await relationalStore.getRdbStore(context, config)
      steps.push('RDB 已打开')

      await store.executeSql('DROP TABLE IF EXISTS probe_chunks')
      await store.executeSql(
        'CREATE TABLE IF NOT EXISTS probe_chunks (' +
          'id TEXT PRIMARY KEY, item_id TEXT NOT NULL, section TEXT, seq INTEGER, text TEXT, tokens TEXT)'
      )

      const body: string = '二里头遗址位于洛阳偃师，学界多认为是夏代晚期都城。'.repeat(10)
      const tokenText: string = '二里头 遗址 洛阳 偃师 夏代 都城 考古'

      const rows: relationalStore.ValuesBucket[] = []
      for (let i = 0; i < 1000; i++) {
        rows.push({
          id: `chunk-${i}`,
          item_id: `item-${i % 80}`,
          section: 'intro',
          seq: i % 20,
          text: body,
          tokens: tokenText,
        })
      }

      const insertStart: number = Date.now()
      const inserted: number = await store.batchInsert('probe_chunks', rows)
      const insertMs: number = Date.now() - insertStart
      steps.push(`批量写入 ${inserted} 条耗时 ${insertMs}ms`)

      const all: relationalStore.RdbPredicates = new relationalStore.RdbPredicates('probe_chunks')
      const countStart: number = Date.now()
      const allResult: relationalStore.ResultSet = await store.query(all, ['id'])
      const countMs: number = Date.now() - countStart
      const allRows: number = allResult.rowCount
      allResult.close()
      steps.push(`全表扫描 ${allRows} 行耗时 ${countMs}ms`)

      const filtered: relationalStore.RdbPredicates = new relationalStore.RdbPredicates('probe_chunks')
      filtered.equalTo('item_id', 'item-5')
      const filterStart: number = Date.now()
      const filterResult: relationalStore.ResultSet = await store.query(filtered, ['id', 'text'])
      const filterMs: number = Date.now() - filterStart
      const filterRows: number = filterResult.rowCount
      filterResult.close()
      steps.push(`条件查询 ${filterRows} 行耗时 ${filterMs}ms`)

      const ok: boolean = inserted === 1000 && allRows === 1000
      return new ProbeResult('D0V-2 关系型存储批量导入', ok, steps.join(' ｜ '), Date.now() - started)
    } catch (err) {
      const msg: string = describeError(err as object)
      return new ProbeResult('D0V-2 关系型存储批量导入', false, `${msg} ｜ 已完成：${steps.join(' ｜ ')}`, Date.now() - started)
    }
  }

  /**
   * D0V-4：rawfile 图片资源加载性能。
   *
   * 样本：50 张 1080×720 的 WebP，单张约 136KB，合计 6.7MB，
   * 与真实预算（约 230 张、单张 80-150KB、合计 30-55MB）同量级。
   *
   * 重建测试图片（图片本身不入版本库）：
   *   cd harmony/YellowRiverArchive/entry/src/main/resources/rawfile/img
   *   for i in $(seq 1 50); do
   *     magick -size 1080x720 plasma:fractal -blur 0x1.5 \
   *       -attenuate 0.3 +noise Gaussian -quality 86 "probe-$i.webp"
   *   done
   *
   * 结论直接影响：图片尺寸策略，以及是否需要分页 / 懒加载。
   */
  static async probeRawfile(context: common.Context): Promise<ProbeResult> {
    const started: number = Date.now()
    const steps: string[] = []

    try {
      const resMgr: resourceManager.ResourceManager = context.resourceManager
      const files: string[] = await resMgr.getRawFileList('img')
      steps.push(`rawfile/img 共 ${files.length} 个文件`)
      if (files.length === 0) {
        return new ProbeResult('D0V-4 图片资源加载', false, '未找到测试图片', Date.now() - started)
      }

      const readStart: number = Date.now()
      let totalBytes: number = 0
      for (const name of files) {
        const content: Uint8Array = await resMgr.getRawFileContent(`img/${name}`)
        totalBytes += content.length
      }
      const readMs: number = Date.now() - readStart
      const mb: number = Math.round((totalBytes / 1024 / 1024) * 10) / 10
      const perImage: number = Math.round(readMs / files.length)
      steps.push(`串行读取 ${files.length} 张耗时 ${readMs}ms（共 ${mb}MB）`)
      steps.push(`平均 ${perImage}ms/张`)

      return new ProbeResult('D0V-4 图片资源加载', totalBytes > 0, steps.join(' ｜ '), Date.now() - started)
    } catch (err) {
      const msg: string = describeError(err as object)
      return new ProbeResult('D0V-4 图片资源加载', false, `${msg} ｜ 已完成：${steps.join(' ｜ ')}`, Date.now() - started)
    }
  }
}
