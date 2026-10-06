/**
 * 查询理解：从自然语言查询里识别结构化条件。
 *
 * 目标场景：「洛阳的唐代窑址」→ city=洛阳、era=汉唐、type=窑址。
 *
 * 实现选择：**子串匹配而非分词后匹配**。查询串很短（通常 3-15 字），
 * 实体名（洛阳 / 窑址 / 唐三彩）本就连续出现在查询里，子串匹配既简单又
 * 不会因分词边界切错而漏识别（例如 jieba 会把"唐三彩"切成"唐/三彩"）。
 *
 * 最大的坑是**单字朝代名的误匹配**：`周` 会命中「周围」，`明` 会命中「文明」，
 * `商` 会命中「商丘」。处理办法是给高风险别名配黑名单，命中黑名单词时跳过。
 */

import type { City, Era, HeritageType, QueryUnderstanding } from '@yra/shared'
import { CITIES } from '@yra/shared'

import type { Db } from '../db/index'

// ---------------------------------------------------------------------------
// 词典
// ---------------------------------------------------------------------------

interface AliasRule<T> {
  readonly alias: string
  readonly value: T
  /** 查询里出现这些词时跳过本别名（只服务于单字别名） */
  readonly blockedBy?: readonly string[]
}

/**
 * 朝代/时期 → 赛题六段时代轴。
 *
 * 六段是赛题规定的粗粒度轴（不是朝代），所以「唐代」「北魏」都要归到「汉唐」。
 * 排序上先长后短，避免「南北朝」被「南朝」抢先匹配。
 */
const ERA_ALIASES: readonly AliasRule<Era>[] = [
  // 仰韶
  { alias: '仰韶文化', value: '仰韶' },
  { alias: '仰韶', value: '仰韶' },
  // 龙山
  { alias: '龙山文化', value: '龙山' },
  { alias: '龙山', value: '龙山' },
  // 夏商
  { alias: '二里头文化', value: '夏商' },
  { alias: '夏代', value: '夏商' },
  { alias: '夏朝', value: '夏商' },
  { alias: '商代', value: '夏商' },
  { alias: '商朝', value: '夏商' },
  { alias: '早商', value: '夏商' },
  { alias: '晚商', value: '夏商' },
  { alias: '殷商', value: '夏商' },
  // 周
  { alias: '西周', value: '周' },
  { alias: '东周', value: '周' },
  { alias: '周代', value: '周' },
  { alias: '周朝', value: '周' },
  { alias: '春秋', value: '周' },
  { alias: '战国', value: '周' },
  // 汉唐
  { alias: '魏晋南北朝', value: '汉唐' },
  { alias: '南北朝', value: '汉唐' },
  { alias: '北魏', value: '汉唐' },
  { alias: '北齐', value: '汉唐' },
  { alias: '北周', value: '汉唐' },
  { alias: '东汉', value: '汉唐' },
  { alias: '西汉', value: '汉唐' },
  { alias: '汉代', value: '汉唐' },
  { alias: '汉朝', value: '汉唐' },
  { alias: '秦代', value: '汉唐' },
  { alias: '隋代', value: '汉唐' },
  { alias: '隋唐', value: '汉唐' },
  { alias: '唐代', value: '汉唐' },
  { alias: '唐朝', value: '汉唐' },
  { alias: '盛唐', value: '汉唐' },
  { alias: '魏晋', value: '汉唐' },
  // 宋
  { alias: '北宋', value: '宋' },
  { alias: '南宋', value: '宋' },
  { alias: '宋代', value: '宋' },
  { alias: '宋朝', value: '宋' },
  { alias: '五代', value: '宋' },
  { alias: '金代', value: '宋' },
  { alias: '辽代', value: '宋' },
  // 宋以后
  { alias: '元代', value: '宋以后' },
  { alias: '元朝', value: '宋以后' },
  { alias: '明代', value: '宋以后' },
  { alias: '明朝', value: '宋以后' },
  { alias: '清代', value: '宋以后' },
  { alias: '清朝', value: '宋以后' },
  { alias: '明清', value: '宋以后' },
  { alias: '民国', value: '宋以后' },
  // ---- 单字别名：高风险，配黑名单 ----
  { alias: '夏', value: '夏商', blockedBy: ['华夏', '夏天', '夏至', '夏令营'] },
  { alias: '商', value: '夏商', blockedBy: ['商量', '商店', '商场', '商业', '商品', '商丘'] },
  { alias: '周', value: '周', blockedBy: ['周围', '周遍', '四周', '一周', '周末', '圆周', '周年'] },
  { alias: '汉', value: '汉唐', blockedBy: ['汉子', '老汉', '武汉', '汉字'] },
  { alias: '唐', value: '汉唐', blockedBy: [] },
  { alias: '宋', value: '宋', blockedBy: [] },
  { alias: '秦', value: '汉唐', blockedBy: [] },
]

/**
 * 遗产类型别名。
 *
 * 注意「遗址」故意不映射：它太泛，出现在几乎所有条目名里，
 * 映射成某个具体类型只会造成误筛。
 */
const TYPE_ALIASES: readonly AliasRule<HeritageType>[] = [
  { alias: '都城遗址', value: '都城遗址' },
  { alias: '都城', value: '都城遗址' },
  { alias: '都邑', value: '都城遗址' },
  { alias: '城址', value: '城址' },
  { alias: '聚落遗址', value: '聚落遗址' },
  { alias: '聚落', value: '聚落遗址' },
  { alias: '村落遗址', value: '聚落遗址' },
  { alias: '墓葬群', value: '墓葬群' },
  { alias: '墓葬', value: '墓葬群' },
  { alias: '墓群', value: '墓葬群' },
  { alias: '古墓', value: '墓葬群' },
  { alias: '陵墓', value: '墓葬群' },
  { alias: '窑址', value: '窑址' },
  { alias: '瓷窑', value: '窑址' },
  { alias: '窑场', value: '窑址' },
  { alias: '古建筑', value: '古建筑' },
  { alias: '古建', value: '古建筑' },
  { alias: '塔', value: '古建筑' },
  { alias: '石窟寺', value: '石窟寺' },
  { alias: '石窟', value: '石窟寺' },
  { alias: '摩崖', value: '石窟寺' },
  { alias: '碑刻', value: '碑刻' },
  { alias: '石碑', value: '碑刻' },
  { alias: '祭祀址', value: '祭祀址' },
  { alias: '祭祀', value: '祭祀址' },
  { alias: '关隘遗址', value: '关隘遗址' },
  { alias: '关隘', value: '关隘遗址' },
  { alias: '关口', value: '关隘遗址' },
]

/**
 * 市辖县区 → 所属城市。
 *
 * 这一层很有用：用户搜「巩义」时，库里记的是 city=郑州，
 * 不做映射就会零结果。只收与沿黄五市相关的县区。
 */
const DISTRICT_ALIASES: readonly AliasRule<City>[] = [
  { alias: '偃师', value: '洛阳' },
  { alias: '孟津', value: '洛阳' },
  { alias: '伊川', value: '洛阳' },
  { alias: '新安', value: '洛阳' },
  { alias: '宜阳', value: '洛阳' },
  { alias: '洛宁', value: '洛阳' },
  { alias: '汝阳', value: '洛阳' },
  { alias: '嵩县', value: '洛阳' },
  { alias: '栾川', value: '洛阳' },
  { alias: '巩义', value: '郑州' },
  { alias: '登封', value: '郑州' },
  { alias: '新郑', value: '郑州' },
  { alias: '新密', value: '郑州' },
  { alias: '荥阳', value: '郑州' },
  { alias: '中牟', value: '郑州' },
  { alias: '杞县', value: '开封' },
  { alias: '通许', value: '开封' },
  { alias: '尉氏', value: '开封' },
  { alias: '兰考', value: '开封' },
  { alias: '祥符', value: '开封' },
  { alias: '灵宝', value: '三门峡' },
  { alias: '渑池', value: '三门峡' },
  { alias: '卢氏', value: '三门峡' },
  { alias: '义马', value: '三门峡' },
  { alias: '陕州', value: '三门峡' },
  { alias: '清丰', value: '濮阳' },
  { alias: '南乐', value: '濮阳' },
  { alias: '范县', value: '濮阳' },
  { alias: '台前', value: '濮阳' },
]

/** 五市名本身 */
const CITY_ALIASES: readonly AliasRule<City>[] = CITIES.map((c) => ({ alias: c, value: c }))

// ---------------------------------------------------------------------------
// 匹配
// ---------------------------------------------------------------------------

/** 别名是否可用（未被黑名单词拦截） */
function aliasAllowed(rule: AliasRule<unknown>, query: string): boolean {
  if (rule.blockedBy === undefined || rule.blockedBy.length === 0) {
    return true
  }
  return !rule.blockedBy.some((bad) => query.includes(bad))
}

function matchAliases<T>(query: string, rules: readonly AliasRule<T>[]): T[] {
  const found: T[] = []
  // 长别名优先：先命中的先占位，短别名仍会被收集（多值筛选是并集语义）
  const sorted: AliasRule<T>[] = [...rules].sort((a, b) => b.alias.length - a.alias.length)
  for (const rule of sorted) {
    if (!query.includes(rule.alias) || !aliasAllowed(rule, query)) {
      continue
    }
    if (!found.includes(rule.value)) {
      found.push(rule.value)
    }
  }
  return found
}

// ---------------------------------------------------------------------------
// 实体库（从数据库构建，含条目名/别名/文物/人物/关键词）
// ---------------------------------------------------------------------------

export interface EntityDictionary {
  /** 专名 → 所属条目 id 列表 */
  readonly terms: Map<string, string[]>
  readonly cities: readonly AliasRule<City>[]
  readonly eras: readonly AliasRule<Era>[]
  readonly types: readonly AliasRule<HeritageType>[]
}

/** 从数据库构建专名词典（服务端启动时调一次） */
export function buildEntityDictionary(db: Db): EntityDictionary {
  const terms = new Map<string, string[]>()
  const add = (term: string, itemId: string): void => {
    const trimmed: string = term.trim()
    if (trimmed.length < 2) {
      return
    }
    const list: string[] | undefined = terms.get(trimmed)
    if (list === undefined) {
      terms.set(trimmed, [itemId])
    } else if (!list.includes(itemId)) {
      list.push(itemId)
    }
  }

  const rows = db
    .prepare('SELECT id, name, payload FROM items')
    .all() as unknown as { id: string; name: string; payload: string }[]

  for (const row of rows) {
    add(row.name, row.id)
    const payload = JSON.parse(row.payload) as {
      aliases?: string[]
      artifacts?: { name: string }[]
      figures?: { name: string }[]
      keywords?: string[]
    }
    for (const alias of payload.aliases ?? []) {
      add(alias, row.id)
    }
    for (const artifact of payload.artifacts ?? []) {
      add(artifact.name, row.id)
    }
    for (const figure of payload.figures ?? []) {
      add(figure.name, row.id)
    }
    for (const keyword of payload.keywords ?? []) {
      add(keyword, row.id)
    }
  }

  return {
    terms,
    cities: CITY_ALIASES,
    eras: ERA_ALIASES,
    types: TYPE_ALIASES,
  }
}

// ---------------------------------------------------------------------------
// 主流程
// ---------------------------------------------------------------------------

/**
 * 专名匹配的最短长度。
 *
 * 太短的查询做「反向包含」匹配会泛滥（如「遗址」会命中库里几乎所有条目），
 * 所以反向匹配只在查询达到此长度时才启用。
 */
const MIN_PARTIAL_MATCH_LENGTH: number = 3

/**
 * 理解查询。
 *
 * 产物分两部分：
 *   - filters：可安全用于结构化筛选的条件
 *   - matchedItems：命中的条目（供图谱增强与实体加权）
 *
 * 专名匹配两个方向都做：
 *   1. 查询包含专名（「巩义唐三彩」含「唐三彩」）
 *   2. 专名包含查询（「二里头」是「二里头遗址」的子串）
 * 第 2 种很必要 —— 用户习惯只打条目名的核心部分，而不是全名。
 */
export function understandQuery(
  query: string,
  dict: EntityDictionary
): QueryUnderstanding {
  const cities: City[] = matchAliases(query, [...dict.cities, ...DISTRICT_ALIASES])
  const eras: Era[] = matchAliases(query, dict.eras)
  const types: HeritageType[] = matchAliases(query, dict.types)

  // 专名按长度降序，长名优先；最多留 8 个，避免把整个查询拆成噪声
  const entities: string[] = []
  const matchedItems: string[] = []
  const allowPartial: boolean = query.length >= MIN_PARTIAL_MATCH_LENGTH
  const sortedTerms: string[] = [...dict.terms.keys()].sort((a, b) => b.length - a.length)

  for (const term of sortedTerms) {
    const forward: boolean = query.includes(term)
    const backward: boolean = allowPartial && term.includes(query)
    if (!forward && !backward) {
      continue
    }
    if (entities.length < 8) {
      entities.push(term)
    }
    for (const itemId of dict.terms.get(term) ?? []) {
      if (!matchedItems.includes(itemId)) {
        matchedItems.push(itemId)
      }
    }
  }

  return { cities, eras, types, entities, matchedItems }
}

/** 词典规模的概览（用于日志与健康检查） */
export function describeDictionary(dict: EntityDictionary): string {
  return [
    `专名 ${dict.terms.size}`,
    `市别名 ${dict.cities.length + DISTRICT_ALIASES.length}`,
    `时代别名 ${dict.eras.length}`,
    `类型别名 ${dict.types.length}`,
  ].join(' / ')
}
