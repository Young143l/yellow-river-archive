import { AppColor, AppFont, AppSize } from '../constants/Theme'

/**
 * 占位视图。
 * 骨架阶段用于标识各页面待实现的内容，正式开发时逐个替换。
 */
@Component
export struct PlaceholderView {
  @Prop title: string = ''
  @Prop desc: string = ''
  /** 对应的开发任务编号，如 D1-7 */
  @Prop taskId: string = ''

  build() {
    Column({ space: AppSize.cardGap }) {
      Text(this.title)
        .fontSize(AppFont.title)
        .fontWeight(FontWeight.Medium)
        .fontColor(AppColor.textPrimary)

      Text(this.desc)
        .fontSize(AppFont.body)
        .fontColor(AppColor.textSecondary)
        .textAlign(TextAlign.Center)

      if (this.taskId.length > 0) {
        Text(`待实现：${this.taskId}`)
          .fontSize(AppFont.caption)
          .fontColor(AppColor.primary)
          .backgroundColor('#F0E6DA')
          .borderRadius(6)
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
      }
    }
    .width('100%')
    .height('100%')
    .padding(AppSize.pagePadding)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(AppColor.background)
  }
}
