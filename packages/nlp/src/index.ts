/**
 * @yra/nlp —— 中文分词与词表。
 *
 * 独立成包的原因只有一个：**构建期建索引与查询期切分必须使用同一实现**。
 * 两边不一致时 BM25 不报错，只是搜不到结果 —— 这类 bug 最难查。
 */

export { STOP_WORDS } from './stopwords'
export {
  Tokenizer,
  extractTermsFromItems,
  forwardMaxMatch,
  loadLexicon,
} from './tokenizer'
export { buildVocab } from './vocab'
export type { VocabEntry } from '@yra/shared'
