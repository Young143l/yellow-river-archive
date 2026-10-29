import { AppColor, FontFamily } from '../constants/Theme'

/**
 * 一行横向滚动的筛选项。
 *
 * 相比原先手写的 Scroll，多两处：
 *   1. 右侧 20px 渐隐遮罩 —— 提示"右边还有"，否则最后一项被切一半
 *      看起来像渲染出错而不是可滑动
 *   2. 选中态用实心石青 + 宋体，与全站一致
 */
@Component
export struct FilterRow {
  @Prop label: string = ''
  @Prop values: string[] = []
  @Prop selected: string[] = []
  onToggle: (value: string) => void = (_value: string) => {}

  build() {
    Row({ space: 8 }) {
      Text(this.label)
        .fontSize(11)
        .fontColor(AppColor.textTertiary)
        .width(26)

      Stack({ alignContent: Alignment.End }) {
        Scroll() {
          Row({ space: 7 }) {
            ForEach(
              this.values,
              (v: string) => {
                Text(v)
                  .fontSize(11)
                  .fontFamily(this.selected.includes(v) ? FontFamily.serifBold : FontFamily.serif)
                  .fontColor(this.selected.includes(v) ? AppColor.surface : AppColor.textSecondary)
                  .backgroundColor(this.selected.includes(v) ? AppColor.primary : AppColor.surface)
                  .borderRadius(13)
                  .borderWidth(1)
                  .borderColor(this.selected.includes(v) ? AppColor.primary : AppColor.divider)
                  .padding({ left: 11, right: 11, top: 5, bottom: 5 })
                  .onClick(() => {
                    this.onToggle(v)
                  })
              },
              (v: string) => `${this.label}-${v}`
            )
          }
          .padding({ right: 20 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')

        // 右端渐隐：盖住被裁切的半个字，视觉上变成"淡出"而非"切断"
        Row()
          .width(20)
          .height('100%')
          .linearGradient({
            angle: 90,
            colors: [[AppColor.background, 0.0], [AppColor.background, 1.0]],
          })
          .opacity(0.92)
          .hitTestBehavior(HitTestMode.None)
      }
      .layoutWeight(1)
      .height(32)
    }
    .width('100%')
    .height(34)
  }
}
