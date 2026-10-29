import { common } from '@kit.AbilityKit'
import { router } from '@kit.ArkUI'

import { CITIES, CORE_ERAS, HERITAGE_TYPES } from '../shared'
import { AppColor, AppFont, AppSize, FontFamily } from '../constants/Theme'
import { PageHeader } from '../components/PageHeader'
import { FilterRow } from '../components/FilterRow'
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
  /** 筛选区是否展开。默认收起 —— 三行 chip 常显会吃掉半屏 */
  @State filterOpen: boolean = false
  /** 档案总数（副标题用） */
  @State total: number = 0
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
      this.total = HeritageDao.list().length
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
  hitCard(hit: SearchHit) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text(hit.name)
          .fontSize(18)
          .fontFamily(FontFamily.serif)
          .fontColor(AppColor.textPrimary)
          .layoutWeight(1)

        Text(hit.reason)
          .fontSize(10)
          .fontColor(AppColor.earth)
          .padding({ left: 2, right: 2 })
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
    .borderRadius(10)
    .borderWidth(1)
    .borderColor(AppColor.divider)
    .onClick(() => {
      this.openDetail(hit.itemId)
    })
  }

  build() {
    Column() {
      // ---- 卷首 ----
      Column({ space: 12 }) {
        PageHeader({
          title: '检索',
          subtitle: `${this.total} 条档案 · 关键词或筛选`,
          compact: true,
        })

        // 搜索框：加放大镜与宋体占位。原先是一个无装饰的圆角矩形，
        // 与全站语汇无关。
        Row({ space: 8 }) {
          // 放大镜：Circle + Line 组合。
          // 用 Path 的 A（圆弧）指令在 ArkUI 上渲染不完整（实测只画出一个小钩），
          // 改用基本图形拼装更可靠。
          Stack({ alignContent: Alignment.TopStart }) {
            Circle({ width: 11, height: 11 })
              .fill(Color.Transparent)
              .stroke(AppColor.textTertiary)
              .strokeWidth(1.5)
              .position({ x: 1, y: 1 })
            Line()
              .startPoint([11, 11])
              .endPoint([15.5, 15.5])
              .stroke(AppColor.textTertiary)
              .strokeWidth(1.5)
          }
          .width(17)
          .height(17)
          TextInput({ text: this.keyword, placeholder: '搜索遗址、文物、诗词、时代' })
            .fontSize(AppFont.caption)
            .placeholderColor(AppColor.textTertiary)
            .backgroundColor(Color.Transparent)
            .padding(0)
            .layoutWeight(1)
            .onChange((value: string) => {
              this.keyword = value
              this.runSearch()
            })
        }
        .width('100%')
        .height(42)
        .padding({ left: 12, right: 12 })
        .backgroundColor(AppColor.surface)
        .borderRadius(10)
        .borderWidth(1)
        .borderColor(AppColor.divider)
      }
      .width('100%')
      .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding, top: 14, bottom: 10 })

      // ---- 筛选：默认收起，只显示已选项 ----
      Column({ space: 6 }) {
        if (this.filterOpen) {
          FilterRow({
            label: '城市',
            values: CITIES,
            selected: this.selectedCities,
            onToggle: (v: string) => {
              this.applyToggle('city', v)
            },
          })
          FilterRow({
            label: '时代',
            values: CORE_ERAS,
            selected: this.selectedEras,
            onToggle: (v: string) => {
              this.applyToggle('era', v)
            },
          })
          FilterRow({
            label: '类型',
            values: HERITAGE_TYPES,
            selected: this.selectedTypes,
            onToggle: (v: string) => {
              this.applyToggle('type', v)
            },
          })
        }

        Row({ space: 8 }) {
          Text(this.filterOpen ? '收起筛选' : '筛选')
            .fontSize(11)
            .fontColor(AppColor.primary)
            .onClick(() => {
              this.filterOpen = !this.filterOpen
            })
          Text(this.filterSummary())
            .fontSize(11)
            .fontColor(AppColor.textTertiary)
            .layoutWeight(1)
          Text(this.resultSummary())
            .fontSize(11)
            .fontColor(AppColor.textTertiary)
        }
        .width('100%')
      }
      .width('100%')
      .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding, bottom: 8 })

      this.hairline()

      if (this.error.length > 0) {
        Text(this.error)
          .fontSize(AppFont.caption)
          .fontColor(AppColor.danger)
          .width('100%')
          .padding({ left: AppSize.pagePadding, top: 8 })
      }

      if (this.hits.length === 0 && !this.searching && this.ready) {
        Column() {
          Text('没有匹配的档案')
            .fontSize(AppFont.body)
            .fontFamily(FontFamily.serif)
            .fontColor(AppColor.textSecondary)
          Text('试试「洛阳」「唐三彩」「仰韶」')
            .fontSize(11)
            .fontColor(AppColor.textTertiary)
            .margin({ top: 6 })
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 10 }) {
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
        .padding({
          left: AppSize.pagePadding,
          right: AppSize.pagePadding,
          top: 10,
        })
      }
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(AppColor.background)
  }

  /** 一条极细分隔线 */
  @Builder
  hairline() {
    Row()
      .width('100%')
      .height(1)
      .backgroundColor(AppColor.divider)
  }

  /** 已选筛选项的摘要文案 */
  private filterSummary(): string {
    const parts: string[] = []
    for (const v of this.selectedCities) {
      parts.push(v)
    }
    for (const v of this.selectedEras) {
      parts.push(v)
    }
    for (const v of this.selectedTypes) {
      parts.push(v)
    }
    return parts.length > 0 ? parts.join(' · ') : '未筛选'
  }
}
