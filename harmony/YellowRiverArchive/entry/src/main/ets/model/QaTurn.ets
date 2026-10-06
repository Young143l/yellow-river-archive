import type { Citation, GraphPath } from '../shared'

/**
 * 一轮问答的模型。
 *
 * 用 `@Observed` 类而不是普通 interface + 整体替换数组元素：
 * 前者允许外部服务（QaClient）直接改字段，ArkUI 仍能感知并刷新；
 * 后者要求每次更新都构造新对象，而更新逻辑在外部类里时，
 * 持有 `this`（struct 实例）的引用**不保证触发刷新** —— 实测就卡在这里，
 * 服务端流式返回了 81 个增量，界面却一直停在「正在检索档案…」。
 */
@Observed
export class QaTurn {
  readonly id: string
  readonly question: string
  answer: string = ''
  citations: Citation[] = []
  graphPaths: GraphPath[] = []
  degraded: boolean = false
  pending: boolean = true
  error: string = ''

  constructor(id: string, question: string) {
    this.id = id
    this.question = question
  }
}
