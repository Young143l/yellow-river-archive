import { PlaceholderView } from '../components/PlaceholderView'

/**
 * 首页：时代轴（仰韶 → 宋）与黄河示意图双视图。
 * 见 docs/开发TODO.md D1-7。
 */
@Component
export struct HomePage {
  build() {
    PlaceholderView({
      title: '首页',
      desc: '以黄河河南段为轴线，按时代轴浏览沿线文化遗产',
      taskId: 'D1-7 时间轴与卡片流',
    })
  }
}
