import { PlaceholderView } from '../components/PlaceholderView'

/**
 * 我的档案：收藏、笔记、标签、学习进度与文档视图。
 * 见 docs/开发TODO.md D4-2、D7-1。
 */
@Component
export struct ProfilePage {
  build() {
    PlaceholderView({
      title: '我的档案',
      desc: '收藏夹、笔记、标签、学习进度与个人知识文档',
      taskId: 'D4-2 / D7-1 个人档案',
    })
  }
}
