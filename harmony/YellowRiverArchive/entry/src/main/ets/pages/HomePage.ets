import { common } from '@kit.AbilityKit'
import { router } from '@kit.ArkUI'

import { CORE_ERAS } from '../shared'
import { AppColor, AppFont, AppSize } from '../constants/Theme'
import { HeritageDao, type EraCount, type HeritageSummary } from '../service/HeritageDao'

/**
 * 首页：黄河时间轴。
 *
 * 以赛题给定的六个时代（仰韶 → 龙山 → 夏商 → 周 → 汉唐 → 宋）为轴，
 * 滑动切换时代，下方是该时代的档案卡片流。
 * 见 docs/开发TODO.md D1-7。
 */
@Component
export struct HomePage {
  @State loading: boolean = true
  @State error: string = ''
  @State counts: EraCount[] = []
  @State selectedEra: string = CORE_ERAS[0]
  @State items: HeritageSummary[] = []
  @State total: number = 0

  aboutToAppear(): void {
    this.load()
  }

  private async load(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.Context
      await HeritageDao.ready(context)
      this.total = HeritageDao.count()
      this.counts = HeritageDao.eraCounts()
      // 默认停在第一个有内容的时代，避免首屏空白
      for (const era of CORE_ERAS) {
        if (this.countOf(era) > 0) {
          this.selectedEra = era
          break
        }
      }
      this.items = HeritageDao.byEra(this.selectedEra)
      this.loading = false
    } catch (err) {
      this.error = `数据导入失败：${(err as Error).message}`
      this.loading = false
    }
  }

  private countOf(era: string): number {
    for (const c of this.counts) {
      if (c.era === era) {
        return c.count
      }
    }
    return 0
  }

  private selectEra(era: string): void {
    this.selectedEra = era
    this.items = HeritageDao.byEra(era)
  }

  private openDetail(id: string): void {
    router.pushUrl({ url: 'pages/DetailPage', params: { id } })
  }

  @Builder
  eraChip(era: string) {
    Column({ space: 2 }) {
      Text(era)
        .fontSize(AppFont.body)
        .fontWeight(this.selectedEra === era ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.selectedEra === era ? AppColor.surface : AppColor.textSecondary)
      Text(`${this.countOf(era)}`)
        .fontSize(AppFont.caption)
        .fontColor(this.selectedEra === era ? AppColor.surface : AppColor.textTertiary)
    }
    .padding({ left: 14, right: 14, top: 8, bottom: 8 })
    .backgroundColor(this.selectedEra === era ? AppColor.primary : AppColor.surface)
    .borderRadius(10)
    .borderWidth(1)
    .borderColor(this.selectedEra === era ? AppColor.primary : AppColor.divider)
    .onClick(() => {
      this.selectEra(era)
    })
  }

  @Builder
  itemCard(item: HeritageSummary) {
    Row({ space: AppSize.cardGap }) {
      Image($rawfile(item.cover))
        .width(92)
        .height(92)
        .borderRadius(8)
        .objectFit(ImageFit.Cover)
        .backgroundColor('#EFE7DA')

      Column({ space: 6 }) {
        Text(item.name)
          .fontSize(AppFont.heading)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Row({ space: 6 }) {
          Text(item.city)
            .fontSize(AppFont.caption)
            .fontColor(AppColor.primary)
          Text('·')
            .fontSize(AppFont.caption)
            .fontColor(AppColor.textTertiary)
          Text(item.types.length > 0 ? item.types[0] : '')
            .fontSize(AppFont.caption)
            .fontColor(AppColor.textSecondary)
          if (item.level.length > 0) {
            Text(item.level)
              .fontSize(11)
              .fontColor(AppColor.textTertiary)
              .backgroundColor('#F0EAE0')
              .borderRadius(4)
              .padding({ left: 6, right: 6, top: 1, bottom: 1 })
          }
        }

        Text(item.summary)
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textSecondary)
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .lineHeight(19)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding(AppSize.cardGap)
    .backgroundColor(AppColor.surface)
    .borderRadius(AppSize.cardRadius)
    .onClick(() => {
      this.openDetail(item.id)
    })
  }

  build() {
    Column({ space: AppSize.cardGap }) {
      Row() {
        Column({ space: 2 }) {
          Text('黄河图志')
            .fontSize(AppFont.title)
            .fontWeight(FontWeight.Medium)
            .fontColor(AppColor.textPrimary)
          Text(`河南段黄河文化遗产 ｜ 已收录 ${this.total} 处`)
            .fontSize(AppFont.caption)
            .fontColor(AppColor.textTertiary)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')

      if (this.loading) {
        Column() {
          Text('正在导入离线档案…')
            .fontSize(AppFont.body)
            .fontColor(AppColor.textSecondary)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.error.length > 0) {
        Column() {
          Text(this.error)
            .fontSize(AppFont.body)
            .fontColor('#B3261E')
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .padding(AppSize.pagePadding)
      } else {
        Scroll() {
          Row({ space: 8 }) {
            ForEach(
              CORE_ERAS,
              (era: string) => {
                this.eraChip(era)
              },
              (era: string) => era
            )
          }
          .padding({ left: 2, right: 2 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        .height(56)

        Text(this.items.length > 0 ? `${this.selectedEra}时期 · ${this.items.length} 处` : `${this.selectedEra}时期暂无收录`)
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textTertiary)
          .width('100%')

        List({ space: AppSize.cardGap }) {
          ForEach(
            this.items,
            (item: HeritageSummary) => {
              ListItem() {
                this.itemCard(item)
              }
            },
            (item: HeritageSummary) => item.id
          )
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .padding(AppSize.pagePadding)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(AppColor.background)
  }
}
