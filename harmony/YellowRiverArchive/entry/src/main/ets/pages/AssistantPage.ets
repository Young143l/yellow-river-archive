import { common } from '@kit.AbilityKit'
import { router } from '@kit.ArkUI'

import type { Citation, GraphPath } from '../shared'
import { AppColor, AppFont, AppSize } from '../constants/Theme'
import { QaClient } from '../service/QaClient'
import { QaTurn } from '../model/QaTurn'

/** 首屏引导问题：不给引导时用户不知道该问什么，问答页会显得空 */
const SUGGESTIONS: string[] = [
  '二里头遗址出土了哪些重要文物',
  '唐三彩主要在哪里烧造',
  '宋代开封有哪些建筑遗存',
]

/**
 * AI 助手：流式问答 + 引用卡片跳详情 + 图谱路径展示。
 * 见 docs/开发TODO.md D5-4。
 */
@Component
export struct AssistantPage {
  @State turns: QaTurn[] = []
  @State draft: string = ''
  @State asking: boolean = false

  private turnSeq: number = 0

  private async submit(question: string): Promise<void> {
    const query: string = question.trim()
    if (query.length === 0 || this.asking) {
      return
    }
    this.asking = true
    this.draft = ''

    this.turnSeq += 1
    const turn: QaTurn = new QaTurn(`turn-${this.turnSeq}`, query)
    this.turns.push(turn)

    const context = this.getUIContext().getHostContext() as common.Context
    await QaClient.ask(context, query, turn)

    // 兜底：若 QaClient 未能收尾（异常路径），避免按钮永久不可用
    if (turn.pending) {
      turn.pending = false
      turn.error = '回答中断，请重试'
    }
    this.asking = false
  }

  private openItem(itemId: string): void {
    router.pushUrl({ url: 'pages/DetailPage', params: { id: itemId } })
  }

  @Builder
  citationCard(citation: Citation, turnId: string) {
    Column({ space: 3 }) {
      Row() {
        Text(citation.title)
          .fontSize(AppFont.caption)
          .fontColor(AppColor.primary)
          .layoutWeight(1)
        Text('查看')
          .fontSize(11)
          .fontColor(AppColor.textTertiary)
      }
      .width('100%')
      Text(citation.snippet)
        .fontSize(11)
        .fontColor(AppColor.textSecondary)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
    }
    .width('100%')
    .padding(8)
    .backgroundColor(AppColor.background)
    .borderRadius(8)
    .onClick(() => {
      this.openItem(citation.itemId)
    })
  }

  /**
   * 渲染一轮对话。
   *
   * 接收**下标**而不是 QaTurn 对象：ADR-021 已记录，ArkUI 的 @Builder
   * 按值传参没有响应性 —— 传对象时 builder 只渲染一次，之后流式增量
   * 全部丢失（实测表现为界面永远停在「正在检索档案…」）。
   * 改为从 this.turns[index] 读，状态变化才能触发重渲染。
   */
  @Builder
  answerBlock(index: number) {
    Column({ space: 8 }) {
      // 提问气泡（右对齐）
      Row() {
        Text(this.turns[index].question)
          .fontSize(AppFont.body)
          .fontColor(AppColor.surface)
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .backgroundColor(AppColor.primary)
          .borderRadius(12)
      }
      .width('100%')
      .justifyContent(FlexAlign.End)

      // 回答（左对齐）
      Column({ space: 8 }) {
        if (this.turns[index].error.length > 0) {
          Text(this.turns[index].error)
            .fontSize(AppFont.body)
            .fontColor('#B3261E')
            .width('100%')
        } else if (this.turns[index].answer.length > 0) {
          Text(this.turns[index].answer)
            .fontSize(AppFont.body)
            .fontColor(AppColor.textPrimary)
            .lineHeight(24)
            .width('100%')
        } else if (this.turns[index].pending) {
          Text('正在检索档案…')
            .fontSize(AppFont.body)
            .fontColor(AppColor.textTertiary)
            .width('100%')
        }

        if (this.turns[index].degraded) {
          Text('生成服务暂不可用，以上为档案原文摘要')
            .fontSize(11)
            .fontColor('#B3261E')
            .width('100%')
        }

        // 引用卡片
        if (this.turns[index].citations.length > 0) {
          Text(`引用 ${this.turns[index].citations.length} 条`)
            .fontSize(11)
            .fontColor(AppColor.textTertiary)
            .width('100%')
          ForEach(
            this.turns[index].citations,
            (citation: Citation) => {
              this.citationCard(citation, this.turns[index].id)
            },
            (citation: Citation) => `${this.turns[index].id}-${citation.chunkId}`
          )
        }

        // 图谱路径
        if (this.turns[index].graphPaths.length > 0) {
          Text('相关关系')
            .fontSize(11)
            .fontColor(AppColor.textTertiary)
            .width('100%')
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(
              this.turns[index].graphPaths,
              (path: GraphPath) => {
                Text(`${path.fromName} → ${path.toName}`)
                  .fontSize(11)
                  .fontColor(AppColor.textSecondary)
                  .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                  .backgroundColor(AppColor.surface)
                  .borderRadius(6)
                  .margin({ right: 6, bottom: 6 })
              },
              (path: GraphPath) => `${this.turns[index].id}-${path.from}-${path.rel}-${path.to}`
            )
          }
          .width('100%')
        }
      }
      .width('100%')
      .padding(AppSize.pagePadding)
      .backgroundColor(AppColor.surface)
      .borderRadius(AppSize.cardRadius)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
  }

  @Builder
  emptyState() {
    Column({ space: 12 }) {
      Text('黄河图志 · 档案助手')
        .fontSize(AppFont.heading)
        .fontWeight(FontWeight.Medium)
        .fontColor(AppColor.textPrimary)
      Text('基于本档案库的检索增强问答，每条结论都标注了来源，可点击核对原文。')
        .fontSize(AppFont.caption)
        .fontColor(AppColor.textSecondary)
        .textAlign(TextAlign.Center)
      Column({ space: 8 }) {
        ForEach(
          SUGGESTIONS,
          (item: string) => {
            Text(item)
              .fontSize(AppFont.caption)
              .fontColor(AppColor.primary)
              .padding({ left: 12, right: 12, top: 8, bottom: 8 })
              .backgroundColor(AppColor.surface)
              .borderRadius(16)
              .onClick(() => {
                this.submit(item)
              })
          },
          (item: string) => item
        )
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding, top: 48 })
    .alignItems(HorizontalAlign.Center)
  }

  build() {
    Column() {
      Text('档案助手')
        .fontSize(AppFont.title)
        .fontWeight(FontWeight.Medium)
        .fontColor(AppColor.textPrimary)
        .width('100%')
        .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding, top: 16, bottom: 12 })

      if (this.turns.length === 0) {
        this.emptyState()
      } else {
        Scroll() {
          Column({ space: AppSize.cardGap }) {
            ForEach(
              this.turns,
              (turn: QaTurn, index: number) => {
                this.answerBlock(index)
              },
              (turn: QaTurn) => turn.id
            )
          }
          .width('100%')
          .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding, bottom: 12 })
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
      }

      // 输入区
      Row({ space: 8 }) {
        TextInput({ text: this.draft, placeholder: '问点什么…' })
          .fontSize(AppFont.body)
          .backgroundColor(AppColor.surface)
          .borderRadius(8)
          .layoutWeight(1)
          .onChange((value: string) => {
            this.draft = value
          })
          .onSubmit(() => {
            this.submit(this.draft)
          })
        Button(this.asking ? '…' : '提问')
          .fontSize(AppFont.caption)
          .fontColor(AppColor.surface)
          .backgroundColor(
            this.draft.trim().length > 0 && !this.asking ? AppColor.primary : AppColor.textTertiary
          )
          .borderRadius(8)
          .onClick(() => {
            this.submit(this.draft)
          })
      }
      .width('100%')
      .padding(AppSize.pagePadding)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppColor.background)
  }
}
