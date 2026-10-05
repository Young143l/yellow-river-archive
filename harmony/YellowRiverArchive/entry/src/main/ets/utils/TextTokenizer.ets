/**
 * 端侧查询分词。
 *
 * 与服务端保持一致：用构建期导出的词表做**前向最大匹配**，把用户输入的查询串
 * 切成词。这样两端用同一套词边界，不会出现"服务器能搜到、手机搜不到"。
 *
 * 为什么不用 jieba：jieba 是真正的分词器，但没有鸿蒙原生版本（NAPI 集成风险高），
 * 而我们的语料只有 80 条、领域明确，词典最大匹配足够。
 */

import { util } from '@kit.ArkTS'

import type { VocabEntry, PresetVocab } from '../shared'

export class TextTokenizer {
  private readonly dict: Set<string>
  private readonly maxLen: number

  private constructor(words: readonly string[]) {
    this.dict = new Set<string>(words)
    let max: number = 2
    for (const w of words) {
      if (w.length > max) {
        max = w.length
      }
    }
    this.maxLen = max
  }

  static fromWords(words: readonly string[]): TextTokenizer {
    return new TextTokenizer(words)
  }

  /** 从 vocab.json 的字节内容构建 */
  static fromVocabBytes(bytes: Uint8Array): TextTokenizer {
    const decoder: util.TextDecoder = util.TextDecoder.create('utf-8')
    const parsed: PresetVocab = JSON.parse(decoder.decodeToString(bytes)) as PresetVocab
    const words: string[] = []
    for (const entry of parsed.entries) {
      words.push(entry.word)
    }
    return new TextTokenizer(words)
  }

  /**
   * 前向最大匹配：从当前位置尝试最长的词典词，命中就切出，否则单字前进。
   * 单字也会输出 —— 中文单字查询（如「塔」）同样需要能命中。
   */
  tokenize(text: string): string[] {
    const tokens: string[] = []
    let i: number = 0
    while (i < text.length) {
      let matched: string = ''
      const upper: number = Math.min(this.maxLen, text.length - i)
      for (let len: number = upper; len >= 2; len--) {
        const candidate: string = text.slice(i, i + len)
        if (this.dict.has(candidate)) {
          matched = candidate
          break
        }
      }
      if (matched.length > 0) {
        tokens.push(matched)
        i += matched.length
      } else {
        tokens.push(text.slice(i, i + 1))
        i += 1
      }
    }
    return tokens
  }
}

/** 词表条目类型在 shared 中定义，这里只做转发方便引用 */
export type { VocabEntry }
