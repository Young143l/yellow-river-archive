/**
 * 中文分词器。
 *
 * **构建期与查询期必须用同一个实例逻辑**——否则索引里的词与查询切出的词对不上，
 * BM25 会静默失效（不是报错，是搜不到）。这是本模块独立成包的唯一原因。
 *
 * 两路合并：
 *   1. jieba 搜索模式（cutForSearch）—— 通用词与切分
 *   2. 领域词典的**前向最大匹配** —— 考古专名
 *
 * 为什么不用 jieba 的用户词典：@node-rs/jieba 的 `loadDict` 只接受编译后的二进制
 * 词典，不认文本用户词典，所以专名由我们自己做最大匹配补上。
 */

import { readFile } from 'node:fs/promises'

import { Jieba } from '@node-rs/jieba'
import { dict } from '@node-rs/jieba/dict'

import type { HeritageItem, VocabEntry } from '@yra/shared'

import { STOP_WORDS } from './stopwords'

/** 标点、符号、空白不进词表 */
function isPunctuationOrSpace(token: string): boolean {
  return /^[\s\p{P}\p{S}]+$/u.test(token)
}

/** 读词典文件：一行一词，`#` 开头为注释 */
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

/** 自动从档案数据里补充领域词：遗址名、别名、文物名、人物名、关键词 */
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
 * 从当前位置起尝试最长的词典词（不超过 maxLen），命中就切出来，否则前进一个字符。
 * 复杂度 O(n × maxLen)，对 300 字量级的文本足够快。
 */
export function forwardMaxMatch(text: string, dictSet: ReadonlySet<string>, maxLen: number): string[] {
  const hits: string[] = []
  let i: number = 0
  while (i < text.length) {
    let matched: string = ''
    const upper: number = Math.min(maxLen, text.length - i)
    for (let len: number = upper; len >= 2; len -= 1) {
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

export class Tokenizer {
  private readonly jieba: Jieba
  private readonly dictSet: ReadonlySet<string>
  private readonly maxTermLen: number

  private constructor(jieba: Jieba, terms: readonly string[]) {
    this.jieba = jieba
    this.dictSet = new Set<string>(terms)
    let maxLen: number = 2
    for (const term of terms) {
      if (term.length > maxLen) {
        maxLen = term.length
      }
    }
    this.maxTermLen = maxLen
  }

  /** 用领域词表构建（构建期传 lexicon + 数据自动抽取，查询期传 vocab.json 的词） */
  static create(terms: readonly string[]): Tokenizer {
    return new Tokenizer(Jieba.withDict(dict), terms)
  }

  /**
   * 从预置包的 vocab 构建。
   *
   * 查询期推荐用这个：vocab.json 由同一次分词产出，用它当词典能保证
   * 「索引里有的词，查询也能切出来」，不依赖 lexicon.txt 是否同步。
   */
  static createFromVocab(vocab: readonly VocabEntry[]): Tokenizer {
    return Tokenizer.create(vocab.map((entry) => entry.word))
  }

  /**
   * 切词：领域专名（前向最大匹配）+ jieba 通用词，去重并保持出现顺序。
   *
   * 专名优先入列，因为它们承载检索精度；jieba 的词作为补充覆盖面。
   */
  tokenize(text: string): string[] {
    const merged: string[] = []
    const seen: Set<string> = new Set<string>()

    const push = (token: string): void => {
      const t: string = token.trim()
      if (t.length === 0 || isPunctuationOrSpace(t) || STOP_WORDS.has(t) || seen.has(t)) {
        return
      }
      seen.add(t)
      merged.push(t)
    }

    for (const term of forwardMaxMatch(text, this.dictSet, this.maxTermLen)) {
      push(term)
    }
    for (const token of this.jieba.cutForSearch(text, false)) {
      push(token)
    }

    return merged
  }

  /**
   * 切查询串。与 tokenize 同逻辑，单独留一个方法是为了将来能加
   * 「查询侧权重/同义扩展」而不影响建索引路径。
   */
  tokenizeQuery(text: string): string[] {
    return this.tokenize(text)
  }
}
