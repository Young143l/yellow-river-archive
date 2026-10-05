/**
 * 语义分块。
 *
 * 目标：把一个档案条目切成若干 100-500 字的检索片段，供端侧关键词检索与服务端
 * 向量检索使用。分块以"内容分区"为边界，不跨分区，保证引用卡片能指明出处。
 *
 * D1 版本：按段落切分；D2 版本会加入 jieba 分词结果写进 tokens 字段。
 */

import type { Chunk, HeritageItem, Section } from '@yra/shared'

/** 单个片段的目标长度上限（字符） */
const MAX_CHARS: number = 480
/** 段落内二次切分时的重叠长度 */
const OVERLAP: number = 40

/** 把一个长段落按标点与长度上限切开 */
function splitLongParagraph(paragraph: string): string[] {
  if (paragraph.length <= MAX_CHARS) {
    return [paragraph]
  }

  const pieces: string[] = []
  let cursor: number = 0
  while (cursor < paragraph.length) {
    let end: number = Math.min(cursor + MAX_CHARS, paragraph.length)
    if (end < paragraph.length) {
      // 尽量在句号、问号、感叹号、分号处断句
      const window: string = paragraph.slice(cursor, end)
      const lastStop: number = Math.max(
        window.lastIndexOf('。'),
        window.lastIndexOf('！'),
        window.lastIndexOf('？'),
        window.lastIndexOf('；')
      )
      if (lastStop > MAX_CHARS * 0.5) {
        end = cursor + lastStop + 1
      }
    }
    pieces.push(paragraph.slice(cursor, end).trim())
    cursor = end - (end < paragraph.length ? OVERLAP : 0)
  }
  return pieces.filter((p) => p.length > 0)
}

function paragraphsOf(text: string): string[] {
  return text
    .split(/\n\s*\n/)
    .map((p) => p.trim())
    .filter((p) => p.length > 0)
}

export function buildChunks(items: readonly HeritageItem[]): Chunk[] {
  const chunks: Chunk[] = []

  const push = (item: HeritageItem, section: Section, seq: number, text: string): void => {
    chunks.push({
      id: `${item.id}#${section}#${seq}`,
      itemId: item.id,
      section,
      seq,
      text,
      // D2 阶段填入 jieba 分词结果；D1 端侧先用原文子串匹配
      tokens: [],
    })
  }

  for (const item of items) {
    let seq: number = 0

    push(item, 'intro', seq++, `【${item.name}】${item.summary}`)
    for (const p of paragraphsOf(item.intro)) {
      for (const piece of splitLongParagraph(p)) {
        push(item, 'intro', seq++, piece)
      }
    }

    seq = 0
    for (const p of paragraphsOf(item.archaeology)) {
      for (const piece of splitLongParagraph(p)) {
        push(item, 'archaeology', seq++, piece)
      }
    }

    seq = 0
    for (const ev of item.events) {
      push(item, 'events', seq++, `${ev.year}年 · ${ev.title}。${ev.desc}`)
    }

    seq = 0
    for (const poem of item.poems) {
      const note: string = poem.note !== undefined ? `（${poem.note}）` : ''
      push(item, 'poems', seq++, `《${poem.title}》${poem.dynasty}·${poem.author}：${poem.content}${note}`)
    }

    if (item.travel !== undefined) {
      const t = item.travel
      const parts: string[] = []
      if (t.hours !== undefined) {
        parts.push(`开放时间：${t.hours}`)
      }
      if (t.ticket !== undefined) {
        parts.push(`门票：${t.ticket}`)
      }
      if (t.best !== undefined) {
        parts.push(`最佳季节：${t.best}`)
      }
      if (t.tips.length > 0) {
        parts.push(`提示：${t.tips.join('；')}`)
      }
      push(item, 'travel', 0, parts.join('。'))
    }
  }

  return chunks
}
