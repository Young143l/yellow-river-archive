import { AppColor, FontFamily } from '../constants/Theme'

/**
 * 页面标题。
 *
 * 抽出来的唯一目的：让六个页面的标题**同一套字体语言**。
 * 之前只有首页用宋体，其余全是系统无衬线 —— 首页像一件作品，
 * 其它页像工具 App，割裂感就是这么来的。
 */
@Component
export struct PageHeader {
  @Prop title: string = ''
  @Prop subtitle: string = ''
  /** 标题下方是否画一条朱砂短横线（首页与部分页面需要） */
  @Prop showRule: boolean = false
  /** 右侧插槽由调用方通过尾部 builder 提供；这里只留间距 */
  @Prop compact: boolean = false

  build() {
    Column({ space: 6 }) {
      Text(this.title)
        .fontSize(this.compact ? 22 : 26)
        .fontFamily(FontFamily.serifBold)
        .fontColor(AppColor.textPrimary)
        .letterSpacing(3)
        .width('100%')

      if (this.showRule) {
        Row()
          .width(38)
          .height(2)
          .backgroundColor(AppColor.seal)
      }

      if (this.subtitle.length > 0) {
        Text(this.subtitle)
          .fontSize(11)
          .fontColor(AppColor.textTertiary)
          .letterSpacing(1)
          .width('100%')
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }
}
