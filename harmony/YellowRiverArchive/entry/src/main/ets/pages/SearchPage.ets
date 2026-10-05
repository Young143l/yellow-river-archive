import { PlaceholderView } from '../components/PlaceholderView'

/**
 * 检索页：关键词检索 + 城市/时代/类型三维筛选。
 * 见 docs/开发TODO.md D1-8。
 */
@Component
export struct SearchPage {
  build() {
    PlaceholderView({
      title: '检索',
      desc: '关键词检索与多维度筛选，支持语义检索开关',
      taskId: 'D1-8 检索与筛选',
    })
  }
}
