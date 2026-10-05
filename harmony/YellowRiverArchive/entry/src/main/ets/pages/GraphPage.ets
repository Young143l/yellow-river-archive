import { PlaceholderView } from '../components/PlaceholderView'

/**
 * 图谱页：全局/个人知识图谱，力导向布局与时间轴联动。
 * 见 docs/开发TODO.md D6-2 ~ D6-5。
 */
@Component
export struct GraphPage {
  build() {
    PlaceholderView({
      title: '知识图谱',
      desc: '文化遗址关联网络、个人知识簇与路径探索',
      taskId: 'D6 图谱可视化',
    })
  }
}
