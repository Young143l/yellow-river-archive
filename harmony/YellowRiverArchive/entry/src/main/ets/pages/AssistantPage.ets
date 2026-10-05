import { PlaceholderView } from '../components/PlaceholderView'

/**
 * 助手页：图谱增强的流式问答，答案带引用与图谱路径。
 * 见 docs/开发TODO.md D5-4。
 */
@Component
export struct AssistantPage {
  build() {
    PlaceholderView({
      title: '黄河文化助手',
      desc: '用自然语言提问，回答附带可跳转的出处与图谱路径',
      taskId: 'D5-4 AI 助手页',
    })
  }
}
