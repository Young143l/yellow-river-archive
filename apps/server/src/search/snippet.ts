/**
 * 摘要片段生成。
 *
 * 不用 FTS5 的 snippet()：那个函数作用在**分词列**上，输出的是词袋拼接，
 * 读起来不像人话。这里在**原始文本**上定位命中词再切窗口，可读性好得多。
 */

/** 命中词在文本中的位置（用于切窗口） */
interface HitPosition {
  readonly index: number
  readonly length: number
}

function findFirstHit(text: string, tokens: readonly string[]): HitPosition | undefined {
  let best: HitPosition | undefined = undefined
  for (const token of tokens) {
    if (token.length === 0) {
      continue
    }
    const index: number = text.indexOf(token)
    if (index < 0) {
      continue
    }
    // 优先取位置最靠前的；同位置取更长的（信息量更大）
    if (best === undefined || index < best.index) {
      best = { index, length: token.length }
    } else if (index === best.index && token.length > best.length) {
      best = { index, length: token.length }
    }
  }
  return best
}

/**
 * 截取包含命中词的窗口。
 *
 * 命中词尽量居中，但靠近首尾时不越界。两侧用省略号标示截断。
 */
export function makeSnippet(text: string, tokens: readonly string[], maxLen: number = 80): string {
  const hit: HitPosition | undefined = findFirstHit(text, tokens)
  if (text.length <= maxLen) {
    return text
  }
  if (hit === undefined) {
    return `${text.slice(0, maxLen)}…`
  }

  // 命中词居中，各留一半空间
  const half: number = Math.floor((maxLen - hit.length) / 2)
  let start: number = Math.max(0, hit.index - half)
  let end: number = Math.min(text.length, start + maxLen)
  start = Math.max(0, end - maxLen)

  const prefix: string = start > 0 ? '…' : ''
  const suffix: string = end < text.length ? '…' : ''
  return `${prefix}${text.slice(start, end)}${suffix}`
}
