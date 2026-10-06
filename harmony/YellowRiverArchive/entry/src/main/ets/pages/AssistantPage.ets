import { common } from '@kit.AbilityKit'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { router } from '@kit.ArkUI'

import type { Citation, GraphPath } from '../shared'
import { AppColor, AppFont, AppSize } from '../constants/Theme'
import { QaBus, QaClient } from '../service/QaClient'

/** 首屏引导问题：不给引导时用户不知道该问什么，问答页会显得空 */
const SUGGESTIONS: string[] = [
  '二里头遗址出土了哪些重要文物',
  '唐三彩主要在哪里烧造',
  '宋代开封有哪些建筑遗存',
]

/**
 * AI 助手：流式问答 + 引用卡片跳详情 + 图谱路径展示。
 *
 * **状态放顶层 @State，不放嵌套对象**：实测把流式增量写进页面持有的对象字段时，
 * ArkUI 不触发重渲染（消息确实到了 —— 设备日志可见大量 on message，
 * 界面却停在 pending）。试过 @Observed / @ObjectLink / @Builder 读 this 三种写法
 * 均无效。因此在 QaClient 里留静态缓冲（QaBus），页面用定时器读进顶层 @State。
 *
 * 这个取舍不好看，但行为确定 —— 比一个「架构更优雅但不确定能不能刷新」的写法有用。
 */
@Component
export struct AssistantPage {
  @State question: string = ''
  @State answer: string = ''
  @State citations: Citation[] = []
  @State graphPaths: GraphPath[] = []
  @State degraded: boolean = false
  @State errorText: string = ''
  @State pending: boolean = false
  @State draft: string = ''
  @State hasAsked: boolean = false

  private pollTimer: number = -1

  aboutToDisappear(): void {
    this.stopPolling()
  }

  private stopPolling(): void {
    if (this.pollTimer !== -1) {
      clearInterval(this.pollTimer)
      this.pollTimer = -1
    }
  }

  /** 每 150ms 把静态缓冲搬进顶层 @State —— 顶层赋值一定能触发刷新 */
  private startPolling(): void {
    this.stopPolling()
    hilog.info(0x0000, 'qaDiag', '轮询已启动')
    this.pollTimer = setInterval(() => {
      hilog.info(0x0000, 'qaDiag', 'tick bus=%{public}d state=%{public}d', QaBus.answer.length, this.answer.length)
      if (QaBus.answer !== this.answer) {
        this.answer = QaBus.answer
      }
      if (QaBus.finished) {
        this.citations = QaBus.citations
        this.graphPaths = QaBus.graphPaths
        this.degraded = QaBus.degraded
        this.errorText = QaBus.error
        if (QaBus.answer.length > 0) {
          this.answer = QaBus.answer
        }
        this.pending = false
        this.stopPolling()
      }
    }, 150)
  }

  private submit(input: string): void {
    const query: string = input.trim()
    if (query.length === 0 || this.pending) {
      return
    }
    this.question = query
    this.answer = ''
    this.citations = []
    this.graphPaths = []
    this.degraded = false
    this.errorText = ''
    this.pending = true
    this.hasAsked = true
    this.draft = ''

    QaBus.reset()
    const context = this.getUIContext().getHostContext() as common.Context
    // 不 await：流式结果通过 QaBus 轮询搬进来
    QaClient.ask(context, query)
    this.startPolling()
  }

  private openItem(itemId: string): void {
    router.pushUrl({ url: 'pages/DetailPage', params: { id: itemId } })
  }

  @Builder
  citationCard(citation: Citation) {
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

  @Builder
  emptyState() {
    Column({ space: 12 }) {
      Text('黄河图志 · 档案助手')
        .fontSize(AppFont.heading)
        .fontWeight(FontWeight.Medium)
        .fontColor(AppColor.textPrimary)
      Text('基于本档案库的检索增强问答，每条结论都标注来源，可点击核对原文。')
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

  @Builder
  answerBlock() {
    Column({ space: 8 }) {
      Row() {
        Text(this.question)
          .fontSize(AppFont.body)
          .fontColor(AppColor.surface)
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .backgroundColor(AppColor.primary)
          .borderRadius(12)
      }
      .width('100%')
      .justifyContent(FlexAlign.End)

      Column({ space: 8 }) {
        if (this.errorText.length > 0) {
          Text(this.errorText)
            .fontSize(AppFont.body)
            .fontColor('#B3261E')
            .width('100%')
        } else if (this.answer.length > 0) {
          Text(this.answer)
            .fontSize(AppFont.body)
            .fontColor(AppColor.textPrimary)
            .lineHeight(24)
            .width('100%')
        } else if (this.pending) {
          Text('正在检索档案…')
            .fontSize(AppFont.body)
            .fontColor(AppColor.textTertiary)
            .width('100%')
        }

        if (this.degraded) {
          Text('生成服务暂不可用，以上为档案原文摘要')
            .fontSize(11)
            .fontColor('#B3261E')
            .width('100%')
        }

        if (this.citations.length > 0) {
          Text(`引用 ${this.citations.length} 条`)
            .fontSize(11)
            .fontColor(AppColor.textTertiary)
            .width('100%')
          ForEach(
            this.citations,
            (citation: Citation) => {
              this.citationCard(citation)
            },
            (citation: Citation) => citation.chunkId
          )
        }

        if (this.graphPaths.length > 0) {
          Text('相关关系')
            .fontSize(11)
            .fontColor(AppColor.textTertiary)
            .width('100%')
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(
              this.graphPaths,
              (path: GraphPath) => {
                Text(`${path.fromName} → ${path.toName}`)
                  .fontSize(11)
                  .fontColor(AppColor.textSecondary)
                  .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                  .backgroundColor(AppColor.background)
                  .borderRadius(6)
                  .margin({ right: 6, bottom: 6 })
              },
              (path: GraphPath) => `${path.from}-${path.rel}-${path.to}`
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

  build() {
    Column() {
      Text('档案助手')
        .fontSize(AppFont.title)
        .fontWeight(FontWeight.Medium)
        .fontColor(AppColor.textPrimary)
        .width('100%')
        .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding, top: 16, bottom: 12 })

      if (!this.hasAsked) {
        this.emptyState()
      } else {
        Scroll() {
          Column() {
            this.answerBlock()
          }
          .width('100%')
          .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding, bottom: 12 })
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
      }

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
        Button(this.pending ? '…' : '提问')
          .fontSize(AppFont.caption)
          .fontColor(AppColor.surface)
          .backgroundColor(
            this.draft.trim().length > 0 && !this.pending ? AppColor.primary : AppColor.textTertiary
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
