/**
 * 极简 Markdown 解析。
 *
 * 只做笔记真正需要的几种：标题、加粗、行内代码、无序列表、引用。
 * 不引入第三方解析库 —— 端侧要打进 HAP，几百 KB 不值当，
 * 而且笔记长度有限，规则也少，手写更可控。
 *
 * 解析分两层：先按行切出块（kind），再在行内切出片段（bold / code）。
 * 这样渲染端可以按 kind 决定字号与缩进，按片段决定字重与颜色。
 */

/** 行内片段 */
export class MdSeg {
  readonly text: string
  readonly bold: boolean
  readonly code: boolean

  constructor(text: string, bold: boolean, code: boolean) {
    this.text = text
    this.bold = bold
    this.code = code
  }
}

/** 块级行 */
export class MdLine {
  /** h1 / h2 / h3 / li / quote / p / blank */
  readonly kind: string
  readonly text: string

  constructor(kind: string, text: string) {
    this.kind = kind
    this.text = text
  }
}

/** 按行切块 */
export function parseMd(src: string): MdLine[] {
  const lines: MdLine[] = []
  const raw: string[] = src.split('\n')
  for (let line of raw) {
    const trimmed: string = line.trim()
    if (trimmed.length === 0) {
      lines.push(new MdLine('blank', ''))
      continue
    }
    if (trimmed.startsWith('### ')) {
      lines.push(new MdLine('h3', trimmed.slice(4)))
    } else if (trimmed.startsWith('## ')) {
      lines.push(new MdLine('h2', trimmed.slice(3)))
    } else if (trimmed.startsWith('# ')) {
      lines.push(new MdLine('h1', trimmed.slice(2)))
    } else if (trimmed.startsWith('- ') || trimmed.startsWith('* ')) {
      lines.push(new MdLine('li', trimmed.slice(2)))
    } else if (trimmed.startsWith('> ')) {
      lines.push(new MdLine('quote', trimmed.slice(2)))
    } else {
      lines.push(new MdLine('p', trimmed))
    }
  }
  // 连续空行压成一行，避免手滑敲出好几个回车把笔记拉得很散
  const compact: MdLine[] = []
  for (const l of lines) {
    if (l.kind === 'blank' && compact.length > 0 && compact[compact.length - 1].kind === 'blank') {
      continue
    }
    compact.push(l)
  }
  while (compact.length > 0 && compact[compact.length - 1].kind === 'blank') {
    compact.pop()
  }
  return compact
}

/**
 * 行内切片段：`code` 与 **bold**。
 *
 * 手写扫描而不是正则 —— ArkTS 的正则支持有限，且这里只需要两种标记，
 * 扫一遍就够。未闭合的标记按普通文字处理，不会把后半句吞掉。
 */
export function splitInline(text: string): MdSeg[] {
  const segs: MdSeg[] = []
  let buf: string = ''
  let i: number = 0
  const n: number = text.length

  const flush = (bold: boolean, code: boolean): void => {
    if (buf.length > 0) {
      segs.push(new MdSeg(buf, bold, code))
      buf = ''
    }
  }

  while (i < n) {
    // 粗体：**xxx**
    if (text.charAt(i) === '*' && i + 1 < n && text.charAt(i + 1) === '*') {
      const end: number = text.indexOf('**', i + 2)
      if (end > i + 1) {
        flush(false, false)
        segs.push(new MdSeg(text.slice(i + 2, end), true, false))
        i = end + 2
        continue
      }
    }
    // 行内代码：`xxx`
    if (text.charAt(i) === '`') {
      const end: number = text.indexOf('`', i + 1)
      if (end > i) {
        flush(false, false)
        segs.push(new MdSeg(text.slice(i + 1, end), false, true))
        i = end + 1
        continue
      }
    }
    buf = buf + text.charAt(i)
    i = i + 1
  }
  flush(false, false)
  return segs
}
