import { AppColor, AppFont, FontFamily } from '../constants/Theme'
import { parseMd, splitInline, type MdLine, type MdSeg } from '../utils/Markdown'

/**
 * 笔记的 Markdown 渲染。
 *
 * 之前笔记按纯文本显示，用户在编辑面板里点了「粗体」，
 * 列表里就看见一对星号 —— 那是语法，不是内容。
 *
 * 只支持笔记会用到的几种：# / ## / ### 标题、**粗体**、`代码`、- 列表、> 引用。
 * 字号基准由调用方给（详情页正文 13，列表 13），标题在此基础上放大。
 */
@Component
export struct MarkdownView {
  @Prop content: string = ''
  @Prop baseSize: number = AppFont.caption

  private lines(): MdLine[] {
    return parseMd(this.content)
  }

  private lineSize(line: MdLine): number {
    if (line.kind === 'h1') {
      return this.baseSize + 6
    }
    if (line.kind === 'h2') {
      return this.baseSize + 3
    }
    if (line.kind === 'h3') {
      return this.baseSize + 1
    }
    return this.baseSize
  }

  private lineColor(line: MdLine): string {
    if (line.kind === 'quote') {
      return AppColor.textSecondary
    }
    if (line.kind === 'h1' || line.kind === 'h2' || line.kind === 'h3') {
      return AppColor.textPrimary
    }
    return AppColor.textSecondary
  }

  build() {
    Column({ space: 4 }) {
      ForEach(
        this.lines(),
        (line: MdLine, index: number) => {
          if (line.kind === 'blank') {
            Row()
              .width('100%')
              .height(6)
          } else if (line.kind === 'quote') {
            // 引用：左侧一道竖线，比缩进更像「引来的话」
            Row({ space: 8 }) {
              Column()
                .width(2)
                .height(this.baseSize + 8)
                .backgroundColor(AppColor.earth)
              Text() {
                ForEach(
                  splitInline(line.text),
                  (seg: MdSeg) => {
                    Span(seg.text)
                      .fontFamily(this.fontOf(seg))
                      .fontStyle(seg.code ? FontStyle.Italic : FontStyle.Normal)
                      .fontColor(seg.code ? AppColor.earth : AppColor.textSecondary)
                  },
                  (seg: MdSeg, i: number) => `q-${i}-${seg.text}`
                )
              }
              .fontSize(this.baseSize)
              .lineHeight(this.baseSize + 8)
              .layoutWeight(1)
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)
          } else {
            Text() {
              if (line.kind === 'li') {
                Span('· ')
                  .fontFamily(FontFamily.serif)
                  .fontColor(AppColor.primary)
              }
              ForEach(
                splitInline(line.text),
                (seg: MdSeg) => {
                  Span(seg.text)
                    .fontFamily(this.fontOf(seg))
                    .fontWeight(this.weightOf(line, seg))
                    .fontColor(this.colorOf(line, seg))
                    .letterSpacing(line.kind.indexOf('h') === 0 ? 1 : 0)
                },
                (seg: MdSeg, i: number) => `${index}-${i}-${seg.text}`
              )
            }
            .fontSize(this.lineSize(line))
            .lineHeight(this.lineSize(line) + 8)
            .width('100%')
            .padding({ left: line.kind === 'li' ? 4 : 0 })
          }
        },
        (line: MdLine, index: number) => `${index}-${line.kind}-${line.text}`
      )
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 代码片段用无衬线，与正文的宋体区分开；粗体走 SemiBold 档 */
  private fontOf(seg: MdSeg): string {
    if (seg.code) {
      return 'HarmonyOS Sans SC'
    }
    return FontFamily.serif
  }

  private weightOf(line: MdLine, seg: MdSeg): number {
    if (line.kind === 'h1' || line.kind === 'h2' || line.kind === 'h3') {
      return FontWeight.Bold
    }
    return seg.bold ? FontWeight.Bold : FontWeight.Normal
  }

  private colorOf(line: MdLine, seg: MdSeg): string {
    if (seg.code) {
      return AppColor.earth
    }
    return this.lineColor(line)
  }
}
