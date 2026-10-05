/**
 * 分词器已下沉到 @yra/nlp（服务端查询期需要同一实现）。
 * 这里保留转出，让既有调用点无需改动。
 */

export {
  buildVocab,
  extractTermsFromItems,
  forwardMaxMatch,
  loadLexicon,
  Tokenizer,
  type VocabEntry,
} from '@yra/nlp'
