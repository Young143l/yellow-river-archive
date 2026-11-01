import { AppColor, AppFont, FontFamily } from '../constants/Theme'

/**
 * 按钮。
 *
 * 两档：
 *   - primary 实心石青全宽胶囊（设计稿里同步、提问都用这个）
 *   - ghost 透明底暖边胶囊（次要动作、已收藏态）
 *
 * 为什么用胶囊而不是小圆角矩形：全站卡片已经是大圆角方盒，
 * 按钮跟着方，层级就糊了；胶囊是唯一的「圆」，一眼能认出可点。
 */
@Component
export struct PillButton {
  @Prop label: string = ''
  @Prop tone: string = 'primary'
  /** 注意：不能叫 enabled —— 与 CustomComponent 内置属性冲突，会编译报错 */
  @Prop active: boolean = true
  @Prop busy: boolean = false
  /** 是否撑满父容器宽度。false 时按内容宽度 */
  @Prop block: boolean = true
  onTap: () => void = () => {
  }

  private isDisabled(): boolean {
    return !this.active || this.busy
  }

  private bg(): ResourceColor {
    if (this.tone === 'ghost') {
      return Color.Transparent
    }
    return this.isDisabled() ? AppColor.textTertiary : AppColor.primary
  }

  build() {
    Text(this.busy ? '处理中…' : this.label)
      .fontSize(AppFont.body)
      .fontFamily(FontFamily.serif)
      .fontColor(this.tone === 'ghost' ? AppColor.primary : AppColor.surface)
      .textAlign(TextAlign.Center)
      .height(44)
      .width(this.block ? '100%' : undefined)
      .padding({ left: this.block ? 0 : 20, right: this.block ? 0 : 20 })
      .backgroundColor(this.bg())
      .borderRadius(22)
      .borderWidth(this.tone === 'ghost' ? 1 : 0)
      .borderColor(AppColor.hairlineWarm)
      .opacity(this.isDisabled() ? 0.55 : 1)
      .onClick(() => {
        if (!this.isDisabled()) {
          this.onTap()
        }
      })
  }
}
