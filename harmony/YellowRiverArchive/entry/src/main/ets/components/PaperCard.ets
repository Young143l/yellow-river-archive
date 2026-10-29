import { AppColor } from '../constants/Theme'

/**
 * 纸面卡。
 *
 * 替代原先的「纯白 + 阴影」卡片。差别在于：
 *   - 底色用 surface（#FBF8F0），与纸面同族，只亮一点点
 *   - 用 1px divider 细边做边界，不靠阴影
 *   - 圆角收到 10
 *
 * 为什么去掉阴影：阴影是"物体悬浮在背景之上"的语言，适合工具型 App；
 * 而全站是纸 + 宋体 + 细线的书卷感，卡片应该像**纸上的一个栏格**，
 * 不是漂在空中的塑料块。去掉阴影后层级靠留白与细边表达，更安静。
 */
@Component
export struct PaperCard {
  @Prop inset: number = 14
  @Prop radius: number = 10
  /** 是否需要描边。密集列表里若已经用分隔线，可关掉描边避免重线 */
  @Prop bordered: boolean = true
  @BuilderParam content: () => void = this.emptyContent

  @Builder
  emptyContent() {
  }

  build() {
    Column() {
      this.content()
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(this.inset)
    .backgroundColor(AppColor.surface)
    .borderRadius(this.radius)
    .borderWidth(this.bordered ? 1 : 0)
    .borderColor(AppColor.divider)
  }
}
