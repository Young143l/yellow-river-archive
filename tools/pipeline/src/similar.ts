/**
 * 关联推荐预计算。
 *
 * 端侧离线可用的关键：把"哪些条目相关、为什么相关"在构建期算好并打包，
 * 这样飞行模式下也能给出可解释的推荐结果。
 *
 * D1 版本：基于结构化信号的加权相似度（时代 / 城市 / 类型 / 关键词 / 同源文物）。
 * D2 版本会并入向量余弦相似度（百炼嵌入）。
 */

import type { HeritageItem, SimilarEntry, SimilarNeighbor } from '@yra/shared'

/** 每条的邻居数量上限 */
const TOP_N: number = 20

interface ScoredNeighbor {
  readonly id: string
  readonly score: number
  readonly reason: string
}

function similarity(a: HeritageItem, b: HeritageItem): ScoredNeighbor {
  let score: number = 0
  const reasons: { text: string; weight: number }[] = []

  if (a.era === b.era) {
    score += 0.35
    reasons.push({ text: `同属${a.era}时期`, weight: 0.35 })
  }
  if (a.city === b.city) {
    score += 0.2
    reasons.push({ text: `同处${a.city}`, weight: 0.2 })
  }

  const sharedTypes: string[] = a.types.filter((t) => b.types.includes(t))
  if (sharedTypes.length > 0) {
    score += 0.25
    reasons.push({ text: `同为${sharedTypes.join('、')}`, weight: 0.25 })
  }

  const sharedKeywords: string[] = a.keywords.filter((k) => b.keywords.includes(k))
  if (sharedKeywords.length > 0) {
    const bonus: number = Math.min(0.2, sharedKeywords.length * 0.07)
    score += bonus
    reasons.push({ text: `共同关键词：${sharedKeywords.slice(0, 2).join('、')}`, weight: bonus })
  }

  // 同名人物或同馆藏文物，视为更强的关联信号
  const sharedFigures: string[] = a.figures
    .map((f) => f.name)
    .filter((n) => b.figures.some((f) => f.name === n))
  if (sharedFigures.length > 0) {
    const firstFigure: string = sharedFigures[0] ?? ''
    score += 0.15
    reasons.push({ text: `共同关联人物：${firstFigure}`, weight: 0.15 })
  }

  reasons.sort((x, y) => y.weight - x.weight)
  const top: { text: string; weight: number } | undefined = reasons[0]
  const reason: string = top !== undefined ? top.text : '文化脉络相近'

  return {
    id: b.id,
    score: Math.round(Math.min(1, score) * 1000) / 1000,
    reason,
  }
}

export function buildSimilar(items: readonly HeritageItem[]): SimilarEntry[] {
  const result: SimilarEntry[] = []

  for (const a of items) {
    const neighbors: SimilarNeighbor[] = items
      .filter((b) => b.id !== a.id)
      .map((b) => similarity(a, b))
      .filter((n) => n.score > 0)
      .sort((x, y) => y.score - x.score)
      .slice(0, TOP_N)

    result.push({ itemId: a.id, neighbors })
  }

  return result
}
