import { common } from '@kit.AbilityKit'
import { router } from '@kit.ArkUI'

import { SECTION_LABELS, type HeritageItem } from '../shared'
import { AppColor, AppFont, AppSize } from '../constants/Theme'
import { HeritageDao, type RelatedItem } from '../service/HeritageDao'

/** 路由参数 */
interface DetailParams {
  readonly id: string
}

/**
 * 详情页：五层内容 + 关联图谱，共六个分区。
 * 见 docs/开发TODO.md D1-9。
 */
@Entry
@Component
struct DetailPage {
  @State item: HeritageItem | undefined = undefined
  @State related: RelatedItem[] = []
  @State loading: boolean = true
  @State error: string = ''
  @State activeIndex: number = 0

  private itemId: string = ''

  aboutToAppear(): void {
    const params = router.getParams() as DetailParams
    if (params !== undefined && params.id !== undefined) {
      this.itemId = params.id
    }
    this.load()
  }

  private async load(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.Context
      await HeritageDao.ready(context)
      this.item = HeritageDao.detail(this.itemId)
      if (this.item === undefined) {
        this.error = `未找到档案：${this.itemId}`
      } else {
        this.related = await HeritageDao.related(context, this.itemId)
      }
    } catch (err) {
      this.error = `加载失败：${(err as Error).message}`
    }
    this.loading = false
  }

  private openDetail(id: string): void {
    router.pushUrl({ url: 'pages/DetailPage', params: { id } })
  }

  @Builder
  sectionText(text: string) {
    Text(text)
      .fontSize(AppFont.body)
      .fontColor(AppColor.textPrimary)
      .lineHeight(24)
      .width('100%')
  }

  @Builder
  sectionEmpty(hint: string) {
    Text(hint)
      .fontSize(AppFont.caption)
      .fontColor(AppColor.textTertiary)
      .width('100%')
      .padding({ top: 12, bottom: 12 })
  }

  @Builder
  introSection(item: HeritageItem) {
    Column({ space: AppSize.cardGap }) {
      this.sectionText(item.intro)

      ForEach(
        item.images,
        (img: ImagePayload) => {
          Column({ space: 4 }) {
            Image($rawfile(img.url))
              .width('100%')
              .height(180)
              .borderRadius(8)
              .objectFit(ImageFit.Cover)
              .backgroundColor('#EFE7DA')
            Text(`${img.caption}（${img.credit} / ${img.license}）`)
              .fontSize(11)
              .fontColor(AppColor.textTertiary)
              .width('100%')
          }
          .width('100%')
        },
        (img: ImagePayload) => img.url
      )
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  archaeologySection(item: HeritageItem) {
    Column({ space: AppSize.cardGap }) {
      this.sectionText(item.archaeology)

      if (item.artifacts.length > 0) {
        Text('出土文物')
          .fontSize(AppFont.body)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
          .width('100%')

        ForEach(
          item.artifacts,
          (a: ArtifactPayload) => {
            Column({ space: 4 }) {
              Text(a.name)
                .fontSize(AppFont.body)
                .fontColor(AppColor.primary)
                .width('100%')
              Text(a.desc)
                .fontSize(AppFont.caption)
                .fontColor(AppColor.textSecondary)
                .lineHeight(19)
                .width('100%')
              if (a.museum !== undefined) {
                Text(`藏于 ${a.museum}`)
                  .fontSize(11)
                  .fontColor(AppColor.textTertiary)
                  .width('100%')
              }
            }
            .width('100%')
            .padding(AppSize.cardGap)
            .backgroundColor(AppColor.surface)
            .borderRadius(AppSize.cardRadius)
          },
          (a: ArtifactPayload) => a.id
        )
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  eventsSection(item: HeritageItem) {
    Column({ space: AppSize.cardGap }) {
      if (item.events.length === 0) {
        this.sectionEmpty('暂无收录的历史事件')
      }
      ForEach(
        item.events,
        (e: EventPayload) => {
          Row({ space: AppSize.cardGap }) {
            Text(e.year)
              .fontSize(AppFont.caption)
              .fontColor(AppColor.surface)
              .backgroundColor(AppColor.primary)
              .borderRadius(6)
              .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            Column({ space: 4 }) {
              Text(e.title)
                .fontSize(AppFont.body)
                .fontColor(AppColor.textPrimary)
                .width('100%')
              Text(e.desc)
                .fontSize(AppFont.caption)
                .fontColor(AppColor.textSecondary)
                .lineHeight(19)
                .width('100%')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
          .padding(AppSize.cardGap)
          .backgroundColor(AppColor.surface)
          .borderRadius(AppSize.cardRadius)
        },
        (e: EventPayload) => `${e.year}-${e.title}`
      )
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  poemsSection(item: HeritageItem) {
    Column({ space: AppSize.cardGap }) {
      if (item.poems.length === 0) {
        this.sectionEmpty('该遗址暂未收录关联诗词（古代尚不知其存在）')
      }
      ForEach(
        item.poems,
        (p: PoemPayload) => {
          Column({ space: 6 }) {
            Text(`${p.title}　${p.dynasty}·${p.author}`)
              .fontSize(AppFont.caption)
              .fontColor(AppColor.textTertiary)
              .width('100%')
            Text(p.content)
              .fontSize(AppFont.body)
              .fontColor(AppColor.textPrimary)
              .lineHeight(26)
              .width('100%')
            if (p.note !== undefined) {
              Text(p.note)
                .fontSize(11)
                .fontColor(AppColor.primary)
                .lineHeight(17)
                .width('100%')
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding(AppSize.cardGap)
          .backgroundColor(AppColor.surface)
          .borderRadius(AppSize.cardRadius)
        },
        (p: PoemPayload) => p.title
      )
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  travelSection(item: HeritageItem) {
    Column({ space: 8 }) {
      if (item.travel === undefined) {
        this.sectionEmpty('暂无文旅信息')
      } else {
        if (item.travel.hours !== undefined) {
          this.infoRow('开放时间', item.travel.hours)
        }
        if (item.travel.ticket !== undefined) {
          this.infoRow('门票', item.travel.ticket)
        }
        if (item.travel.best !== undefined) {
          this.infoRow('推荐季节', item.travel.best)
        }
        ForEach(
          item.travel.tips,
          (tip: string) => {
            this.infoRow('提示', tip)
          },
          (tip: string) => tip
        )
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  infoRow(label: string, value: string) {
    Row({ space: AppSize.cardGap }) {
      Text(label)
        .fontSize(AppFont.caption)
        .fontColor(AppColor.textTertiary)
        .width(64)
      Text(value)
        .fontSize(AppFont.caption)
        .fontColor(AppColor.textPrimary)
        .lineHeight(20)
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding(AppSize.cardGap)
    .backgroundColor(AppColor.surface)
    .borderRadius(AppSize.cardRadius)
  }

  @Builder
  graphSection() {
    Column({ space: AppSize.cardGap }) {
      if (this.related.length === 0) {
        this.sectionEmpty('暂无关联条目')
      }
      ForEach(
        this.related,
        (r: RelatedItem) => {
          Row({ space: AppSize.cardGap }) {
            Column({ space: 4 }) {
              Text(r.name)
                .fontSize(AppFont.body)
                .fontColor(AppColor.textPrimary)
                .width('100%')
              Text(r.reason)
                .fontSize(11)
                .fontColor(AppColor.textTertiary)
                .width('100%')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Text(r.score.toFixed(2))
              .fontSize(11)
              .fontColor(AppColor.primary)
          }
          .width('100%')
          .padding(AppSize.cardGap)
          .backgroundColor(AppColor.surface)
          .borderRadius(AppSize.cardRadius)
          .onClick(() => {
            this.openDetail(r.id)
          })
        },
        (r: RelatedItem) => r.id
      )
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  header(item: HeritageItem) {
    Column({ space: 8 }) {
      Image($rawfile(item.images.length > 0 ? item.images[0].url : ''))
        .width('100%')
        .height(200)
        .borderRadius(AppSize.cardRadius)
        .objectFit(ImageFit.Cover)
        .backgroundColor('#EFE7DA')

      Text(item.name)
        .fontSize(24)
        .fontWeight(FontWeight.Medium)
        .fontColor(AppColor.textPrimary)
        .width('100%')

      Row({ space: 8 }) {
        Text(`${item.city} · ${item.era}`)
          .fontSize(AppFont.caption)
          .fontColor(AppColor.primary)
        ForEach(
          item.types,
          (t: string) => {
            Text(t)
              .fontSize(11)
              .fontColor(AppColor.textSecondary)
              .backgroundColor('#F0EAE0')
              .borderRadius(4)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          },
          (t: string) => t
        )
        if (item.level !== undefined) {
          Text(item.level)
            .fontSize(11)
            .fontColor(AppColor.textTertiary)
        }
      }
      .width('100%')

      Text(item.summary)
        .fontSize(AppFont.body)
        .fontColor(AppColor.textSecondary)
        .lineHeight(24)
        .width('100%')
        .padding({ top: 4 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        Text('返回')
          .fontSize(AppFont.body)
          .fontColor(AppColor.primary)
          .onClick(() => {
            router.back()
          })
        Text(this.item !== undefined ? this.item.name : '档案详情')
          .fontSize(AppFont.heading)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding, top: 12, bottom: 12 })

      if (this.loading) {
        Column() {
          Text('加载中…')
            .fontSize(AppFont.body)
            .fontColor(AppColor.textSecondary)
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.item === undefined) {
        Column() {
          Text(this.error.length > 0 ? this.error : '未找到档案')
            .fontSize(AppFont.body)
            .fontColor('#B3261E')
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column({ space: AppSize.cardGap }) {
            this.header(this.item)

            Tabs({ barPosition: BarPosition.Start, index: this.activeIndex }) {
              TabContent() {
                this.introSection(this.item)
              }
              .tabBar(SECTION_LABELS[0].label)

              TabContent() {
                this.archaeologySection(this.item)
              }
              .tabBar(SECTION_LABELS[1].label)

              TabContent() {
                this.eventsSection(this.item)
              }
              .tabBar(SECTION_LABELS[2].label)

              TabContent() {
                this.poemsSection(this.item)
              }
              .tabBar(SECTION_LABELS[3].label)

              TabContent() {
                this.travelSection(this.item)
              }
              .tabBar(SECTION_LABELS[4].label)

              TabContent() {
                this.graphSection()
              }
              .tabBar(SECTION_LABELS[5].label)
            }
            .barMode(BarMode.Scrollable)
            .barHeight(48)
            .height(560)
            .onChange((index: number) => {
              this.activeIndex = index
            })
          }
          .width('100%')
          .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding, bottom: 24 })
          .alignItems(HorizontalAlign.Start)
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppColor.background)
  }
}

/** 以下三个接口对应 payload 中的嵌套结构，用于 ForEach 的元素类型标注 */

interface ImagePayload {
  readonly url: string
  readonly caption: string
  readonly credit: string
  readonly license: string
}

interface ArtifactPayload {
  readonly id: string
  readonly name: string
  readonly desc: string
  readonly museum?: string
}

interface EventPayload {
  readonly year: string
  readonly title: string
  readonly desc: string
}

interface PoemPayload {
  readonly title: string
  readonly author: string
  readonly dynasty: string
  readonly content: string
  readonly note?: string
}
