/**
 * 结构化知识文档生成。
 *
 * 对应赛题原文「形成结构化知识文档」。做法是把用户自己的收藏与笔记，
 * 按「时代 → 遗址」两级分组聚合成一份可交付的 Markdown 文档。
 *
 * 几个取舍：
 *   - **只收有内容的条目**：收藏了但没写笔记的也收（收藏本身就是学习行为的痕迹），
 *     但一条内容都没有的条目会造成空章节，所以至少要有一条笔记或有收藏才收录
 *   - **时代用赛题六段轴**：与全站一致，用户不会看到两套时间体系
 *   - **Markdown 而非富文本**：纯文本可版本管理、可读、可直接粘进任何编辑器，
 *     而富文本要面对格式兼容问题
 */

import { common } from '@kit.AbilityKit'
import { fileIo } from '@kit.CoreFileKit'

import type { HeritageItem, Note } from '../shared'
import { CORE_ERAS } from '../shared'
import { HeritageDao } from './HeritageDao'
import { PersonalDao } from './PersonalDao'

/** 文档中的一个条目节点 */
export interface DocumentEntry {
  readonly itemId: string
  readonly name: string
  readonly city: string
  readonly era: string
  readonly types: string
  readonly level: string
  readonly summary: string
  readonly favorited: boolean
  readonly notes: string[]
}

/** 文档中的一个时代分组 */
export interface DocumentSection {
  readonly era: string
  readonly entries: DocumentEntry[]
}

export interface StructuredDocument {
  readonly title: string
  readonly generatedAt: number
  readonly sections: DocumentSection[]
  readonly totalEntries: number
  readonly totalNotes: number
}

export class DocumentBuilder {
  /**
   * 生成结构化文档。
   *
   * 收录规则：有笔记的条目一定收录；只有收藏没有笔记的也收录（标注为「已收藏」）。
   * 这样文档既是一份学习笔记，也是一份收藏清单 —— 而非只反映其中一面。
   */
  static async build(context: common.Context): Promise<StructuredDocument> {
    await HeritageDao.ready(context)

    const favorites = await PersonalDao.listFavorites(context)
    const notes: Note[] = await PersonalDao.listNotes(context)

    // 收集涉及的条目 id（收藏优先，笔记可能落在未收藏的条目上）
    const itemIds: string[] = []
    for (const fav of favorites) {
      if (!itemIds.includes(fav.targetId)) {
        itemIds.push(fav.targetId)
      }
    }
    for (const note of notes) {
      if (!itemIds.includes(note.targetId)) {
        itemIds.push(note.targetId)
      }
    }

    // 按时代归组
    const grouped: Map<string, DocumentEntry[]> = new Map<string, DocumentEntry[]>()
    for (const era of CORE_ERAS) {
      grouped.set(era, [])
    }
    let totalNotes: number = 0

    for (const itemId of itemIds) {
      const item: HeritageItem | undefined = HeritageDao.detail(itemId)
      if (item === undefined) {
        continue
      }

      const itemNotes: string[] = []
      for (const note of notes) {
        if (note.targetId === itemId) {
          itemNotes.push(note.content)
        }
      }
      totalNotes += itemNotes.length

      const isFavorited: boolean = favorites.some((f) => f.targetId === itemId)
      // 收藏与笔记都没有的条目不收录 —— 产生不了任何内容
      if (!isFavorited && itemNotes.length === 0) {
        continue
      }

      const typesText: string = item.types.length > 0 ? item.types.join('、') : ''
      const entry: DocumentEntry = {
        itemId,
        name: item.name,
        city: item.city,
        era: item.era,
        types: typesText,
        level: item.level !== undefined ? item.level : '',
        summary: item.summary,
        favorited: isFavorited,
        notes: itemNotes,
      }

      const bucket: DocumentEntry[] = grouped.get(item.era) ?? []
      bucket.push(entry)
      grouped.set(item.era, bucket)
    }

    // 时代按赛题六段轴排序；「宋以后」这类未在轴内的排在最后
    const sections: DocumentSection[] = []
    let totalEntries: number = 0
    for (const era of CORE_ERAS) {
      const entries: DocumentEntry[] = grouped.get(era) ?? []
      if (entries.length === 0) {
        continue
      }
      entries.sort((a, b) => a.name.localeCompare(b.name))
      sections.push({ era, entries })
      totalEntries += entries.length
    }

    return {
      title: '黄河图志 · 我的学习档案',
      generatedAt: new Date().getTime(),
      sections,
      totalEntries,
      totalNotes,
    }
  }

  /** 渲染为 Markdown */
  static toMarkdown(doc: StructuredDocument): string {
    const lines: string[] = []
    lines.push(`# ${doc.title}`)
    lines.push('')
    lines.push(`生成时间：${DocumentBuilder.formatDate(doc.generatedAt)}`)
    lines.push(`收录条目：${doc.totalEntries} 条 ｜ 笔记：${doc.totalNotes} 条`)
    lines.push('')

    for (const section of doc.sections) {
      lines.push(`## ${section.era}`)
      lines.push('')
      for (const entry of section.entries) {
        const meta: string[] = [entry.city]
        if (entry.types.length > 0) {
          meta.push(entry.types)
        }
        if (entry.level.length > 0) {
          meta.push(entry.level)
        }
        lines.push(`### ${entry.name}`)
        lines.push('')
        lines.push(`> ${meta.join(' · ')}${entry.favorited ? ' · 已收藏' : ''}`)
        lines.push('')
        lines.push(entry.summary)
        lines.push('')
        if (entry.notes.length > 0) {
          lines.push('**我的笔记**')
          lines.push('')
          for (const note of entry.notes) {
            lines.push(`- ${note}`)
          }
          lines.push('')
        }
      }
    }

    if (doc.totalEntries === 0) {
      lines.push('_尚未收藏或记录任何条目。在档案详情页点「收藏」或写下笔记后，这里会自动汇总。_')
      lines.push('')
    }

    return lines.join('\n')
  }

  /** 导出 Markdown 到沙箱，返回文件路径 */
  static async exportToFile(context: common.Context, doc: StructuredDocument): Promise<string> {
    const path: string = `${context.filesDir}/yra-notes.md`
    const text: string = DocumentBuilder.toMarkdown(doc)
    const file = fileIo.openSync(
      path,
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC
    )
    try {
      fileIo.writeSync(file.fd, text)
    } finally {
      fileIo.closeSync(file)
    }
    return path
  }

  static formatDate(ms: number): string {
    const d: Date = new Date(ms)
    const pad = (n: number): string => (n < 10 ? `0${n}` : `${n}`)
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`
  }
}
