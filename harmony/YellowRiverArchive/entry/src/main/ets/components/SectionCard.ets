import { AppColor, AppFont, FontFamily, AppSize } from '../constants/Theme'

/**
 * 分区卡。
 *
 * 与 PaperCard 的区别：描边用暖金（hairlineWarm）而不是灰色分隔线，
 * 且可选一条金色顶边（topRule）—— 设计稿里图谱底部信息条与「跨设备同步」
 * 卡都用了这个顶边，作用是给出「这一块是一节」的分量。
 *
 * 统一到本组件后，页面里不再各自写 borderWidth / borderRadius。
 */
@Component
export struct SectionCard {
  @Prop title: string = ''
  /** 标题右侧的补充文字，例如数字或状态 */
  @Prop aside: string = ''
  @Prop asideColor: string = AppColor.primary
  @Prop inset: number = AppSize.cardGap
  @Prop radius: number = AppSize.cardRadius
  /** 金色顶边。用于强调「这一节」 */
  @Prop topRule: boolean = false
  @BuilderParam content: () => void = this.emptyContent

  @Builder
  emptyContent() {
  }

  build() {
    Column({ space: 10 }) {
      if (this.topRule) {
        Row()
          .width('100%')
          .height(2)
          .backgroundColor(AppColor.gold)
          .margin({ bottom: 2 })
      }

      if (this.title.length > 0) {
        Row() {
          Text(this.title)
            .fontSize(AppFont.heading)
            .fontFamily(FontFamily.serifBold)
            .fontColor(AppColor.textPrimary)
            .letterSpacing(1)
            .layoutWeight(1)

          if (this.aside.length > 0) {
            Text(this.aside)
              .fontSize(AppFont.display)
              .fontFamily(FontFamily.serifBold)
              .fontColor(this.asideColor)
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }

      this.content()
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(this.inset)
    .backgroundColor(AppColor.surface)
    .borderRadius(this.radius)
    .borderWidth(1)
    .borderColor(AppColor.hairlineWarm)
  }
}
