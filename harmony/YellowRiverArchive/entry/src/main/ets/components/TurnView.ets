import { router } from '@kit.ArkUI'

import type { Citation, GraphPath } from '../shared'
import { AppColor, AppFont, AppSize } from '../constants/Theme'
import { QaTurn } from '../model/QaTurn'

/**
 * 单轮问答的渲染组件。
 *
 * 用独立组件 + `@ObjectLink` 而不是在父页面的 @Builder 里读状态：
 * ArkUI 观察 `@Observed` 对象的**唯一可靠方式**是 `@ObjectLink` ——
 * 父组件里 `this.turns[index].answer` 的读取不会被追踪，
 * 因此流式增量写进去也不会触发重渲染（实测表现为界面永远停在 pending）。
 */
@Component
export struct TurnView {
  @ObjectLink turn: QaTurn

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

  build() {
    Column({ space: 8 }) {
      Row() {
        Text(this.turn.question)
          .fontSize(AppFont.body)
          .fontColor(AppColor.surface)
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .backgroundColor(AppColor.primary)
          .borderRadius(12)
      }
      .width('100%')
      .justifyContent(FlexAlign.End)

      Column({ space: 8 }) {
        if (this.turn.error.length > 0) {
          Text(this.turn.error)
            .fontSize(AppFont.body)
            .fontColor('#B3261E')
            .width('100%')
        } else if (this.turn.answer.length > 0) {
          Text(this.turn.answer)
            .fontSize(AppFont.body)
            .fontColor(AppColor.textPrimary)
            .lineHeight(24)
            .width('100%')
        } else if (this.turn.pending) {
          Text('正在检索档案…')
            .fontSize(AppFont.body)
            .fontColor(AppColor.textTertiary)
            .width('100%')
        }

        if (this.turn.degraded) {
          Text('生成服务暂不可用，以上为档案原文摘要')
            .fontSize(11)
            .fontColor('#B3261E')
            .width('100%')
        }

        if (this.turn.citations.length > 0) {
          Text(`引用 ${this.turn.citations.length} 条`)
            .fontSize(11)
            .fontColor(AppColor.textTertiary)
            .width('100%')
          ForEach(
            this.turn.citations,
            (citation: Citation) => {
              this.citationCard(citation)
            },
            (citation: Citation) => citation.chunkId
          )
        }

        if (this.turn.graphPaths.length > 0) {
          Text('相关关系')
            .fontSize(11)
            .fontColor(AppColor.textTertiary)
            .width('100%')
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(
              this.turn.graphPaths,
              (path: GraphPath) => {
                Text(`${path.fromName} → ${path.toName}`)
                  .fontSize(11)
                  .fontColor(AppColor.textSecondary)
                  .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                  .backgroundColor(AppColor.surface)
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
}
