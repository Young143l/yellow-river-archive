/**
 * 词表构建。
 *
 * 端侧需要在本地对查询串做最大匹配切分（不能依赖云端），因此构建期把高频词
 * 导出为 vocab.json 随预置包下发。服务端也用同一份 vocab 当查询期词典，
 * 保证端云两侧切分一致。
 */

import type { VocabEntry } from '@yra/shared'

/** 统计词频并取前 N 个词，按频次降序、同频按字典序 */
export function buildVocab(tokenLists: readonly string[][], topN: number): VocabEntry[] {
  const freq: Map<string, number> = new Map<string, number>()
  for (const tokens of tokenLists) {
    for (const token of tokens) {
      freq.set(token, (freq.get(token) ?? 0) + 1)
    }
  }

  const entries: VocabEntry[] = Array.from(freq.entries()).map(([word, count]) => ({
    word,
    freq: count,
  }))
  entries.sort((a, b) => {
    if (b.freq !== a.freq) {
      return b.freq - a.freq
    }
    return a.word.localeCompare(b.word)
  })
  return entries.slice(0, topN)
}
