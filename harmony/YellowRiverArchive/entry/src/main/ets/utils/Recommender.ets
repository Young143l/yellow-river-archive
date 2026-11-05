import type { HeritageItem, SimilarEntry } from '../shared'
import type { Favorite } from '../shared'
import type { VisitRow } from '../service/PersonalDao'

/**
 * 行为推荐（赛题第 5 条：「基于用户收藏与浏览行为数据，通过算法自动计算内容相似度」）。
 *
 * 之前只有内容相似度（similar.json，建索引时预计算），收藏与浏览两张表一直在写
 * 却没有任何算法消费 —— 推荐千人一面。这里把行为信号接进来：
 *
 *   最终分 = 内容相似度 × (1 + 0.6 × 画像匹配)
 *
 * 画像按三个维度（时代 / 城市 / 类型）累计行为权重：
 *   收藏一条 = 该条目的各维度 +1.0（强信号）
 *   浏览一条 = +0.4 × exp(-天数/14)（弱信号，且随时间衰减，两周半衰）
 *   已经读过的条目本身在推荐里降权 ×0.3 —— 「猜你想看」不该全是刚看过的
 *
 * 全部端侧计算（符合「计算可在本地或云端完成」），不新增网络请求。
 */

export interface Recommendation {
  readonly itemId: string
  readonly score: number
  /** 人话理由。冷启动时是「按内容相似度推荐」，不假装知道用户喜欢什么 */
  readonly reason: string
}

interface Profile {
  /** 维度键：era:仰韶 / city:洛阳 / type:聚落遗址 */
  weights: Map<string, number>
  /** 行为覆盖的条目数（收藏 + 浏览去重），用于理由文案 */
  seeds: number
}

const DIM_ERA: string = 'era'
const DIM_CITY: string = 'city'
const DIM_TYPE: string = 'type'

export class Recommender {
  private readonly items: Map<string, HeritageItem>
  private readonly profile: Profile
  private readonly readAt: Map<string, number>

  private constructor(items: Map<string, HeritageItem>, profile: Profile, readAt: Map<string, number>) {
    this.items = items
    this.profile = profile
    this.readAt = readAt
  }

  /** 画像为空（无收藏无浏览）时返回的实例也能工作，只是退化为纯内容相似度 */
  static build(items: HeritageItem[], favorites: Favorite[], visits: VisitRow[]): Recommender {
    const byId: Map<string, HeritageItem> = new Map<string, HeritageItem>()
    for (const item of items) {
      byId.set(item.id, item)
    }

    const weights: Map<string, number> = new Map<string, number>()
    const now: number = new Date().getTime()
    const seeds: Set<string> = new Set<string>()

    const add = (item: HeritageItem | undefined, weight: number): void => {
      if (item === undefined) {
        return
      }
      seeds.add(item.id)
      const bump = (dim: string, key: string): void => {
        const k: string = `${dim}:${key}`
        weights.set(k, (weights.get(k) ?? 0) + weight)
      }
      bump(DIM_ERA, item.era)
      bump(DIM_CITY, item.city)
      for (const t of item.types) {
        bump(DIM_TYPE, t)
      }
    }

    for (const f of favorites) {
      add(byId.get(f.targetId), 1.0)
    }
    for (const v of visits) {
      // 两周半衰：14 天前的浏览只剩一半权重，一个月前约 1/4
      const days: number = Math.max(0, (now - v.visitedAt) / 86400000)
      add(byId.get(v.itemId), 0.4 * Math.exp(-days / 14))
    }

    const readAt: Map<string, number> = new Map<string, number>()
    for (const v of visits) {
      const prev: number = readAt.get(v.itemId) ?? 0
      if (v.visitedAt > prev) {
        readAt.set(v.itemId, v.visitedAt)
      }
    }
    return new Recommender(byId, { weights: weights, seeds: seeds.size }, readAt)
  }

  /** 有没有行为数据。首页「猜你想看」据此决定是否渲染 */
  hasBehavior(): boolean {
    return this.profile.seeds > 0
  }

  /** 详情页：给定条目的相关推荐，按行为重排 */
  recommendFor(currentId: string, similar: SimilarEntry | undefined, topK: number): Recommendation[] {
    const out: Recommendation[] = []
    const neighbors = similar?.neighbors ?? []
    for (const n of neighbors) {
      const target: HeritageItem | undefined = this.items.get(n.id)
      if (target === undefined) {
        continue
      }
      const boost: number = this.boostOf(target, currentId)
      const score: number = n.score * (1 + 0.6 * boost)
      out.push({
        itemId: n.id,
        score,
        reason: this.reasonOf(target, n.score),
      })
    }
    out.sort((a, b) => b.score - a.score)
    return out.slice(0, topK)
  }

  /** 首页「猜你想看」：从全部条目里挑与画像最贴近、且没读过的 */
  topPicks(topK: number): Recommendation[] {
    const out: Recommendation[] = []
    for (const item of this.items.values()) {
      // 读过的降权而不是剔除 —— 看过一半的条目可能正想回来看完
      const penalty: number = this.readAt.has(item.id) ? 0.3 : 1.0
      const boost: number = this.boostOf(item, '')
      if (boost <= 0) {
        continue
      }
      out.push({
        itemId: item.id,
        score: boost * penalty,
        reason: this.reasonOf(item, 0),
      })
    }
    out.sort((a, b) => b.score - a.score)
    return out.slice(0, topK)
  }

  /** 条目与画像的贴合度（0-1 量级） */
  private boostOf(item: HeritageItem, excludeId: string): number {
    if (item.id === excludeId) {
      return 0
    }
    let hit: number = 0
    let total: number = 0
    const take = (dim: string, key: string): void => {
      const w: number = this.profile.weights.get(`${dim}:${key}`) ?? 0
      total += w
      if (w > 0) {
        hit += w
      }
    }
    take(DIM_ERA, item.era)
    take(DIM_CITY, item.city)
    for (const t of item.types) {
      take(DIM_TYPE, t)
    }
    // 画像里所有权重都来自用户行为；全中才是 1
    return total > 0 ? hit / total : 0
  }

  /** 理由：画像最强的维度决定主句；冷启动老实说按内容相似度 */
  private reasonOf(item: HeritageItem, contentScore: number): string {
    let bestDim: string = ''
    let bestKey: string = ''
    let bestWeight: number = 0
    const scan = (dim: string, key: string): void => {
      const w: number = this.profile.weights.get(`${dim}:${key}`) ?? 0
      if (w > bestWeight) {
        bestWeight = w
        bestDim = dim
        bestKey = key
      }
    }
    scan(DIM_ERA, item.era)
    scan(DIM_CITY, item.city)
    for (const t of item.types) {
      scan(DIM_TYPE, t)
    }
    if (bestWeight <= 0) {
      return '按内容相似度推荐'
    }
    const noun: string =
      bestDim === DIM_ERA ? `${bestKey} 时期` : (bestDim === DIM_TYPE ? bestKey : `${bestKey}的`)
    // 维度决定了量词与连接方式：城市说「洛阳的」，类型说「聚落遗址」
    if (bestDim === DIM_CITY) {
      return `你在关注 ${bestKey} 的遗存`
    }
    if (bestDim === DIM_TYPE) {
      return `与你看过的 ${bestKey} 同类`
    }
    return `你在关注 ${noun}的遗存`
  }
}
