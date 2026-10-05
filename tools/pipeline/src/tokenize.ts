/**
 * 分词与词表构建。
 *
 * 两路合并：
 *   1. jieba 的搜索模式分词（cutForSearch）—— 负责通用词与切分
 *   2. 领域词典的**前向最大匹配** —— 负责考古专名
 *
 * 为什么不用 jieba 的用户词典：@node-rs/jieba 的 `loadDict` 只接受编译后的
 * 二进制词典，不认文本格式的用户词典，因此专名由我们自己做最大匹配补上。
 *
 * 产物：
 *   - chunks.jsonl 里每个 chunk 的 tokens 字段（供端侧检索）
 *   - vocab.json（词频表，供端侧词典最大匹配切分查询串）
 */

import { readFile } from 'node:fs/promises'

import { Jieba } from '@node-rs/jieba'
import { dict } from '@node-rs/jieba/dict'

import type { HeritageItem, VocabEntry } from '@yra/shared'

/** 词表条目（与 @yra/shared 的 VocabEntry 一致，避免两处定义） */
export type { VocabEntry } from '@yra/shared'

/** 停用词：单字虚词与标点，进词表只会增加噪声 */
const STOP_WORDS: Set<string> = new Set<string>([
  '的', '了', '在', '是', '和', '与', '及', '或', '而', '也', '都', '就', '被', '把',
  '为', '以', '于', '由', '从', '到', '对', '等', '这', '那', '其', '之', '中', '上',
  '下', '内', '外', '后', '前', '年', '月', '日', '一', '二', '三', '四', '五', '六',
  '七', '八', '九', '十', '百', '千', '万', '个', '处', '座', '件', '种', '些', '所',
])

/** 标点与空白不需要进词表 */
function isPunctuationOrSpace(token: string): boolean {
  return /^[\s\p{P}\p{S}]+$/u.test(token)
}

/** 读词典文件：一行一词，# 开头为注释 */
export async function loadLexicon(path: string): Promise<string[]> {
  const raw: string = await readFile(path, 'utf8')
  const terms: string[] = []
  for (const line of raw.split('\n')) {
    const trimmed: string = line.trim()
    if (trimmed.length === 0 || trimmed.startsWith('#')) {
      continue
    }
    terms.push(trimmed)
  }
  return terms
}

/** 自动从档案数据里补充领域词：遗址名、别名、文物名、人物名 */
export function extractTermsFromItems(items: readonly HeritageItem[]): string[] {
  const terms: Set<string> = new Set<string>()
  for (const item of items) {
    terms.add(item.name)
    for (const alias of item.aliases) {
      terms.add(alias)
    }
    for (const artifact of item.artifacts) {
      terms.add(artifact.name)
    }
    for (const figure of item.figures) {
      terms.add(figure.name)
    }
    for (const keyword of item.keywords) {
      terms.add(keyword)
    }
  }
  return Array.from(terms)
}

/**
 * 前向最大匹配。
 *
 * 从当前位置起，尝试匹配最长（不超过 maxLen）的词典词；命中就切出来，
 * 否则按单字前进。复杂度 O(n × maxLen)，对 300 字左右的 chunk 足够快。
 */
export function forwardMaxMatch(text: string, dictSet: Set<string>, maxLen: number): string[] {
  const hits: string[] = []
  let i: number = 0
  while (i < text.length) {
    let matched: string = ''
    const upper: number = Math.min(maxLen, text.length - i)
    for (let len: number = upper; len >= 2; len--) {
      const candidate: string = text.slice(i, i + len)
      if (dictSet.has(candidate)) {
        matched = candidate
        break
      }
    }
    if (matched.length > 0) {
      hits.push(matched)
      i += matched.length
    } else {
      i += 1
    }
  }
  return hits
}

/** 分词器：合并 jieba 结果与领域词典命中 */
export class Tokenizer {
  private readonly jieba: Jieba
  private readonly dictSet: Set<string>
  private readonly maxTermLen: number

  private constructor(jieba: Jieba, terms: readonly string[]) {
    this.jieba = jieba
    this.dictSet = new Set<string>(terms)
    let maxLen: number = 2
    for (const t of terms) {
      if (t.length > maxLen) {
        maxLen = t.length
      }
    }
    this.maxTermLen = maxLen
  }

  static create(terms: readonly string[]): Tokenizer {
    const jieba: Jieba = Jieba.withDict(dict)
    return new Tokenizer(jieba, terms)
  }

  /** 把一段文本切成词：jieba 词 + 领域专名，去重并保持出现顺序 */
  tokenize(text: string): string[] {
    const merged: string[] = []
    const seen: Set<string> = new Set<string>()

    const push = (token: string): void => {
      const t: string = token.trim()
      if (t.length === 0 || isPunctuationOrSpace(t) || STOP_WORDS.has(t)) {
        return
      }
      if (seen.has(t)) {
        return
      }
      seen.add(t)
      merged.push(t)
    }

    // 领域专名优先（它们承载检索精度）
    for (const term of forwardMaxMatch(text, this.dictSet, this.maxTermLen)) {
      push(term)
    }
    // 再补 jieba 的通用分词
    for (const token of this.jieba.cutForSearch(text, false)) {
      push(token)
    }

    return merged
  }
}

/** 统计词频并取前 N 个词，作为端侧词表 */
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
