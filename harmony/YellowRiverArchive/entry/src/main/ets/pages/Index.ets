import { AppColor, FontFamily } from '../constants/Theme'
import { AssistantPage } from './AssistantPage'
import { GraphPage } from './GraphPage'
import { HomePage } from './HomePage'
import { ProfilePage } from './ProfilePage'
import { SearchPage } from './SearchPage'

/**
 * 应用主容器：底部五 Tab。
 * 页面切换用 Tabs 组件，不使用路由跳转，保证切换时页面状态可保持。
 */
@Entry
@Component
struct Index {
  @State activeIndex: number = 0
  private controller: TabsController = new TabsController()

  /**
   * 单个 Tab。
   *
   * 只做三件事：宋体、选中项加一条短下划线、未选中压淡。
   * 没有图标 —— 全站的语汇是宋体 + 留白 + 细线，塞一排通用图标反而杂。
   * 五个词（首页/检索/图谱/助手/我的）本身已经足够清楚。
   */
  @Builder
  tabItem(index: number, label: string) {
    Column({ space: 5 }) {
      Text(label)
        .fontSize(12)
        .fontFamily(this.activeIndex === index ? FontFamily.serifBold : FontFamily.serif)
        .fontColor(this.activeIndex === index ? AppColor.tabActive : AppColor.tabInactive)
        .letterSpacing(1.5)

      // 下划线：宽度固定 16，选中才出现。用宽度而非透明度切换，
      // 避免"半透明的线"这种含糊状态
      Row()
        .width(this.activeIndex === index ? 16 : 0)
        .height(1.5)
        .backgroundColor(AppColor.primary)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }

  build() {
    Tabs({ barPosition: BarPosition.End, index: this.activeIndex, controller: this.controller }) {
      TabContent() {
        HomePage()
      }
      .tabBar(this.tabItem(0, '首页'))

      TabContent() {
        SearchPage()
      }
      .tabBar(this.tabItem(1, '检索'))

      TabContent() {
        GraphPage()
      }
      .tabBar(this.tabItem(2, '图谱'))

      TabContent() {
        AssistantPage()
      }
      .tabBar(this.tabItem(3, '助手'))

      TabContent() {
        ProfilePage()
      }
      .tabBar(this.tabItem(4, '我的'))
    }
    .barHeight(62)
    .barMode(BarMode.Fixed)
    .scrollable(false)
    .animationDuration(180)
    // 顶线改用渐隐的细线：通栏实线会把 Tab 栏切成一个"盒子"，
    // 两端渐隐则像是纸面上的一道折痕
    .divider({
      strokeWidth: 1,
      startMargin: 24,
      endMargin: 24,
      color: AppColor.divider,
    })
    .backgroundColor(AppColor.background)
    .onChange((index: number) => {
      this.activeIndex = index
    })
    .width('100%')
    .height('100%')
  }
}
