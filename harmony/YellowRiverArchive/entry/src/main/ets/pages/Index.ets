import { AppColor, AppFont } from '../constants/Theme'
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

  @Builder
  tabItem(index: number, label: string) {
    Column() {
      Text(label)
        .fontSize(AppFont.tab)
        .fontWeight(this.activeIndex === index ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.activeIndex === index ? AppColor.tabActive : AppColor.tabInactive)
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
    .barHeight(56)
    .barMode(BarMode.Fixed)
    .scrollable(false)
    .animationDuration(0)
    .divider({ strokeWidth: 1, color: AppColor.divider })
    .backgroundColor(AppColor.background)
    .onChange((index: number) => {
      this.activeIndex = index
    })
    .width('100%')
    .height('100%')
  }
}
