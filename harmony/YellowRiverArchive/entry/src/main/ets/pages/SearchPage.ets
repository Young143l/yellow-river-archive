import { common } from '@kit.AbilityKit'
import { router } from '@kit.ArkUI'

import { CITIES, CORE_ERAS, HERITAGE_TYPES } from '../shared'
import { AppColor, AppFont, AppSize } from '../constants/Theme'
import { HeritageDao, type HeritageFilter } from '../service/HeritageDao'
import { SearchService, type SearchHit } from '../service/SearchService'

/**
 * 检索页：关键词检索 + 城市/时代/类型三维筛选。
 * 见 docs/开发TODO.md D1-8。
 *
 * 注意：@Builder 的**值参数不具响应性**——把状态当参数传进去，状态变化不会刷新 UI。
 * 因此这里的 Builder 只接收"静态标识"（kind），筛选状态一律通过 this 直接读取。
 */
@Component
export struct SearchPage {
  @State keyword: string = ''
  @State selectedCities: string[] = []
  @State selectedEras: string[] = []
  @State selectedTypes: string[] = []
  @State hits: SearchHit[] = []
  @State ready: boolean = false
  @State searching: boolean = false
  @State error: string = ''

  aboutToAppear(): void {
    this.init()
  }

  private async init(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.Context
      await HeritageDao.ready(context)
      this.ready = true
      await this.runSearch()
    } catch (err) {
      this.error = `初始化失败：${(err as Error).message}`
    }
  }

  private currentFilter(): HeritageFilter {
    return {
      cities: this.selectedCities,
      eras: this.selectedEras,
      types: this.selectedTypes,
    }
  }

  private async runSearch(): Promise<void> {
    if (!this.ready) {
      return
    }
    // 在调用点锁定查询串，避免异步过程中状态变化导致结果与展示不一致
    const query: string = this.keyword
    const filter: HeritageFilter = this.currentFilter()
    this.searching = true
    try {
      const context = this.getUIContext().getHostContext() as common.Context
      this.hits = await SearchService.search(context, query, filter)
      this.error = ''
    } catch (err) {
      this.error = `检索失败：${(err as Error).message}`
      this.hits = []
    }
    this.searching = false
  }

  private valuesOf(kind: string): string[] {
    if (kind === 'city') {
      return CITIES
    }
    if (kind === 'era') {
      return CORE_ERAS
    }
    return HERITAGE_TYPES
  }

  private selectedOf(kind: string): string[] {
    if (kind === 'city') {
      return this.selectedCities
    }
    if (kind === 'era') {
      return this.selectedEras
    }
    return this.selectedTypes
  }

  private labelOf(kind: string): string {
    if (kind === 'city') {
      return '城市'
    }
    if (kind === 'era') {
      return '时代'
    }
    return '类型'
  }

  private applyToggle(kind: string, value: string): void {
    if (kind === 'city') {
      this.selectedCities = this.toggle(this.selectedCities, value)
    } else if (kind === 'era') {
      this.selectedEras = this.toggle(this.selectedEras, value)
    } else {
      this.selectedTypes = this.toggle(this.selectedTypes, value)
    }
    this.runSearch()
  }

  private toggle(list: string[], value: string): string[] {
    const next: string[] = []
    let removed: boolean = false
    for (const v of list) {
      if (v === value) {
        removed = true
      } else {
        next.push(v)
      }
    }
    if (!removed) {
      next.push(value)
    }
    return next
  }

  private openDetail(id: string): void {
    router.pushUrl({ url: 'pages/DetailPage', params: { id } })
  }

  /** 命中通道的中文标签，便于确认走的是哪条检索路径 */
  private channelLabel(channel: string): string {
    if (channel === 'both') {
      return '字段+正文'
    }
    if (channel === 'text') {
      return '正文'
    }
    if (channel === 'field') {
      return '字段'
    }
    return '筛选'
  }

  private resultSummary(): string {
    const kw: string = this.keyword.trim()
    if (this.searching) {
      return '检索中…'
    }
    if (kw.length === 0) {
      return `筛选结果 ${this.hits.length} 条`
    }
    return `查询「${kw}」 · 命中 ${this.hits.length} 条`
  }

  @Builder
  filterRow(kind: string) {
    Row({ space: 8 }) {
      Text(this.labelOf(kind))
        .fontSize(AppFont.caption)
        .fontColor(AppColor.textTertiary)
        .width(30)

      Scroll() {
        Row({ space: 8 }) {
          ForEach(
            this.valuesOf(kind),
            (v: string) => {
              Text(v)
                .fontSize(AppFont.caption)
                .fontColor(this.selectedOf(kind).includes(v) ? AppColor.surface : AppColor.textSecondary)
                .backgroundColor(this.selectedOf(kind).includes(v) ? AppColor.primary : AppColor.surface)
                .borderRadius(14)
                .borderWidth(1)
                .borderColor(this.selectedOf(kind).includes(v) ? AppColor.primary : AppColor.divider)
                .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                .onClick(() => {
                  this.applyToggle(kind, v)
                })
            },
            (v: string) => `${kind}-${v}`
          )
        }
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .layoutWeight(1)
    }
    .width('100%')
    .height(40)
  }

  @Builder
  hitCard(hit: SearchHit) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text(hit.name)
          .fontSize(AppFont.heading)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
          .layoutWeight(1)

        Text(hit.reason)
          .fontSize(11)
          .fontColor(AppColor.primary)
          .backgroundColor(AppColor.divider)
          .borderRadius(4)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
      }
      .width('100%')

      Text(`${hit.city} · ${hit.era} ｜ ${this.channelLabel(hit.channel)}`)
        .fontSize(AppFont.caption)
        .fontColor(AppColor.textTertiary)

      Text(hit.snippet)
        .fontSize(AppFont.caption)
        .fontColor(AppColor.textSecondary)
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .lineHeight(19)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(AppSize.cardGap)
    .backgroundColor(AppColor.surface)
    .borderRadius(AppSize.cardRadius)
    .onClick(() => {
      this.openDetail(hit.itemId)
    })
  }

  build() {
    Column({ space: AppSize.cardGap }) {
      TextInput({ text: this.keyword, placeholder: '搜索遗址、文物、诗词、时代' })
        .fontSize(AppFont.body)
        .height(44)
        .backgroundColor(AppColor.surface)
        .borderRadius(AppSize.cardRadius)
        .onChange((value: string) => {
          this.keyword = value
          this.runSearch()
        })

      this.filterRow('city')
      this.filterRow('era')
      this.filterRow('type')

      Text(this.resultSummary())
        .fontSize(AppFont.caption)
        .fontColor(AppColor.textTertiary)
        .width('100%')

      if (this.error.length > 0) {
        Text(this.error)
          .fontSize(AppFont.caption)
          .fontColor(AppColor.danger)
          .width('100%')
      }

      List({ space: AppSize.cardGap }) {
        ForEach(
          this.hits,
          (hit: SearchHit) => {
            ListItem() {
              this.hitCard(hit)
            }
          },
          (hit: SearchHit) => `${hit.itemId}-${hit.channel}-${hit.score}`
        )
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)

      if (this.hits.length === 0 && !this.searching && this.ready) {
        Text('没有匹配的档案，试试「洛阳」「唐三彩」「仰韶」')
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textTertiary)
          .width('100%')
          .textAlign(TextAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
    .padding(AppSize.pagePadding)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(AppColor.background)
  }
}
