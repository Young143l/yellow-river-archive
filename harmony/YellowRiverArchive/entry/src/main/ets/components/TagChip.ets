import { AppColor, FontFamily } from '../constants/Theme'

/**
 * 实心小标签。
 *
 * 设计稿里条目名后面跟着一个赭黄小方块，标出这条记录的来源通道。
 * 之前这里是纯文字换色 —— 文字换色在密集列表里几乎看不见，
 * 实心块才能起到「标记」的作用。
 *
 * tone 决定底色：earth 赭黄（默认、地理/来源）、primary 石青（交互类）、
 * vegetation 石绿（状态类，极少用）。
 */
@Component
export struct TagChip {
  @Prop label: string = ''
  @Prop tone: string = 'earth'

  private fillColor(): string {
    if (this.tone === 'primary') {
      return AppColor.primary
    }
    if (this.tone === 'vegetation') {
      return AppColor.vegetation
    }
    return AppColor.chipFill
  }

  build() {
    Text(this.label)
      .fontSize(10)
      .fontFamily(FontFamily.serif)
      .fontColor(AppColor.surface)
      .lineHeight(15)
      .padding({ left: 5, right: 5 })
      .backgroundColor(this.fillColor())
      .borderRadius(3)
  }
}
