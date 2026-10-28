import { common } from '@kit.AbilityKit'
import { router } from '@kit.ArkUI'

import type { HeritageSummary } from '../service/HeritageDao'
import { HeritageDao } from '../service/HeritageDao'
import {
  MapProjection,
  RIVER_CITIES,
  RIVER_HENAN,
  projectionFor,
} from '../constants/RiverPath'
import { AppColor, AppFont, AppSize } from '../constants/Theme'

const ALL_ERAS: string = '全部'

/** 画布上的一个遗址落点 */
class SiteMarker {
  readonly item: HeritageSummary
  readonly x: number
  readonly y: number

  constructor(item: HeritageSummary, x: number, y: number) {
    this.item = item
    this.x = x
    this.y = y
  }
}

/**
 * 首页：黄河示意地图。
 *
 * 设计取舍：**主体是河，不是卡片。**
 * 上一版做成了横向卡片卷轴，结果五张大卡片占满屏幕，河道沦为背景装饰 ——
 * 与「沿黄河流域呈现」的本意相反。
 *
 * 现在一屏就能看全五处遗址在黄河上的位置关系，点圆点才展开细节。
 * 这是「图志」的读法：先看格局，再看条目。
 */
@Component
export struct HomePage {
  @State loading: boolean = true
  @State error: string = ''
  @State items: HeritageSummary[] = []
  @State total: number = 0
  @State selectedEra: string = ALL_ERAS
  @State selectedId: string = ''
  @State cardVisible: boolean = false
  @State cardOffset: number = 420

  private settings: RenderingContextSettings = new RenderingContextSettings(true)
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings)
  /** 全部遗址（用于确定地图边界，不受筛选影响，保证地图不会随筛选跳动） */
  private allItems: HeritageSummary[] = []
  private markers: SiteMarker[] = []
  private ready: boolean = false
  /** 当前浮卡展示的条目。非 @State：只有 cardVisible 变化才需要重绘卡片 */
  private cardItem: HeritageSummary | undefined = undefined

  aboutToAppear(): void {
    this.load()
  }

  private async load(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.Context
      await HeritageDao.ready(context)
      this.allItems = HeritageDao.list()
      this.total = this.allItems.length
      this.applyFilter()
      this.loading = false
      if (this.ready) {
        this.draw()
      }
    } catch (err) {
      this.error = `档案加载失败：${err}`
      this.loading = false
    }
  }

  private applyFilter(): void {
    let filtered: HeritageSummary[] = this.allItems
    if (this.selectedEra !== ALL_ERAS) {
      filtered = this.allItems.filter((item: HeritageSummary) => item.era === this.selectedEra)
    }
    // 按经度升序 —— 自西向东，与河流流向一致，也方便按顺序讲解
    filtered.sort((a: HeritageSummary, b: HeritageSummary) => a.lng - b.lng)
    this.items = filtered
    if (this.ready) {
      this.draw()
    }
  }

  private selectEra(era: string): void {
    this.selectedEra = era
    // 换筛选后原有选中项可能已不在列表里，一并清掉
    this.dismissCard()
    this.applyFilter()
  }

  private countOf(era: string): number {
    if (era === ALL_ERAS) {
      return this.total
    }
    return this.allItems.filter((item: HeritageSummary) => item.era === era).length
  }

  // ---------------------------------------------------------------- 绘制

  /**
   * 计算投影并重绘。
   *
   * 边界取自**全部遗址**而非筛选结果：否则切时代时地图会重新缩放，
   * 圆点在画面上跳来跳去，读不出「位置没变、只是被过滤了」。
   */
  private draw(): void {
    const w: number = this.ctx.width
    const h: number = this.ctx.height
    if (w <= 0 || h <= 0) {
      return
    }
    this.ctx.clearRect(0, 0, w, h)

    const source: HeritageSummary[] = this.allItems.length > 0 ? this.allItems : this.items
    if (source.length === 0) {
      return
    }

    let minLat: number = Number.MAX_VALUE
    let maxLat: number = -Number.MAX_VALUE
    let minLng: number = Number.MAX_VALUE
    let maxLng: number = -Number.MAX_VALUE
    for (const item of source) {
      minLat = Math.min(minLat, item.lat)
      maxLat = Math.max(maxLat, item.lat)
      minLng = Math.min(minLng, item.lng)
      maxLng = Math.max(maxLng, item.lng)
    }

    // 地图占画布中部：上方留标题空间，下方留给可能出现的浮卡
    const sidePad: number = 34
    const mapW: number = Math.max(60, w - sidePad * 2)
    const mapH: number = Math.min(mapW * 0.92, h * 0.52)
    const mapTop: number = h * 0.20
    const proj: MapProjection = projectionFor(
      minLat, maxLat, minLng, maxLng, sidePad, mapTop, mapW, mapH, 0.14
    )

    this.drawRiver(proj, w)
    this.drawCities(proj, w)
    this.buildMarkers(proj)
    this.drawMarkers()
  }

  /** 河道：粗带 + 细芯线，做出水面的层次 */
  private drawRiver(proj: MapProjection, canvasW: number): void {
    const points: number[] = []
    for (const p of RIVER_HENAN) {
      points.push(proj.x(p.lng))
      points.push(proj.y(p.lat))
    }

    // 外层河带
    this.ctx.beginPath()
    this.ctx.moveTo(points[0], points[1])
    for (let i = 2; i < points.length; i += 2) {
      this.ctx.lineTo(points[i], points[i + 1])
    }
    this.ctx.lineWidth = 13
    this.ctx.lineCap = 'round'
    this.ctx.lineJoin = 'round'
    this.ctx.strokeStyle = '#CFE0E6'
    this.ctx.stroke()

    // 芯线：细一条，读起来才像水而不是色块
    this.ctx.beginPath()
    this.ctx.moveTo(points[0], points[1])
    for (let i = 2; i < points.length; i += 2) {
      this.ctx.lineTo(points[i], points[i + 1])
    }
    this.ctx.lineWidth = 2
    this.ctx.strokeStyle = '#95B7C2'
    this.ctx.stroke()
  }

  /** 沿线城市名：只作方位参照，不做强调 */
  private drawCities(proj: MapProjection, canvasW: number): void {
    this.ctx.font = 'bold 14px sans-serif'
    this.ctx.textAlign = 'center'
    for (const city of RIVER_CITIES) {
      let x: number = proj.x(city.lng)
      // 河道首尾会画出画外，城市名钳在画布内，否则会被裁掉
      x = Math.max(28, Math.min(canvasW - 28, x))
      const y: number = proj.y(city.lat) - 16
      // 城市名压在河带上时没有这层描边会糊掉
      this.ctx.lineWidth = 3
      this.ctx.strokeStyle = AppColor.background
      this.ctx.strokeText(city.name, x, y)
      this.ctx.fillStyle = '#8B7F71'
      this.ctx.fillText(city.name, x, y)
      // 一个小横杠，表示这是沿线上的参照点
      this.ctx.beginPath()
      this.ctx.moveTo(x - 4, y + 6)
      this.ctx.lineTo(x + 4, y + 6)
      this.ctx.lineWidth = 1
      this.ctx.strokeStyle = '#D3C9BC'
      this.ctx.stroke()
    }
    // 河名：点在河道中段上方，明确告诉观众这是黄河
    const midX: number = proj.x(113.20)
    const midY: number = proj.y(34.90) - 26
    this.ctx.font = 'bold 15px sans-serif'
    this.ctx.lineWidth = 4
    this.ctx.strokeStyle = AppColor.background
    this.ctx.strokeText('黄 河', midX, midY)
    this.ctx.fillStyle = '#7C9CA8'
    this.ctx.fillText('黄 河', midX, midY)

    this.ctx.textAlign = 'left'
  }

  private buildMarkers(proj: MapProjection): void {
    this.markers = []
    for (const item of this.items) {
      this.markers.push(new SiteMarker(item, proj.x(item.lng), proj.y(item.lat)))
    }
  }

  private drawMarkers(): void {
    for (const marker of this.markers) {
      const isSelected: boolean = marker.item.id === this.selectedId
      const r: number = isSelected ? 11 : 7

      if (isSelected) {
        // 选中态的外环：比实心圆大一圈，靠留白把视线吸过来
        this.ctx.beginPath()
        this.ctx.arc(marker.x, marker.y, r + 7, 0, Math.PI * 2)
        this.ctx.fillStyle = 'rgba(140, 59, 30, 0.16)'
        this.ctx.fill()
      }

      this.ctx.beginPath()
      this.ctx.arc(marker.x, marker.y, r, 0, Math.PI * 2)
      this.ctx.fillStyle = AppColor.primary
      this.ctx.fill()
      this.ctx.lineWidth = 2
      this.ctx.strokeStyle = '#FFFFFF'
      this.ctx.stroke()

      // 名称只在选中时出现：全画会挤成一团，也失去「点一下才知道」的动机
      if (isSelected) {
        this.ctx.font = '13px sans-serif'
        this.ctx.textAlign = 'center'
        this.ctx.fillStyle = AppColor.textPrimary
        this.ctx.fillText(marker.item.name, marker.x, marker.y - r - 12)
        this.ctx.textAlign = 'left'
      }
    }
  }

  // ---------------------------------------------------------------- 交互

  private handleTap(x: number, y: number): void {
    let best: SiteMarker | undefined = undefined
    let bestDist: number = 32 * 32
    for (const marker of this.markers) {
      const dx: number = marker.x - x
      const dy: number = marker.y - y
      const d2: number = dx * dx + dy * dy
      if (d2 < bestDist) {
        bestDist = d2
        best = marker
      }
    }
    if (best === undefined) {
      this.dismissCard()
      return
    }
    this.showCard(best.item)
  }

  private showCard(item: HeritageSummary): void {
    this.cardItem = item
    this.selectedId = item.id
    this.cardVisible = true
    this.draw()
    // 260ms 是「够快不拖沓、又不显得突兀」的常用区间
    animateTo({ duration: 260, curve: Curve.EaseOut }, () => {
      this.cardOffset = 0
    })
  }

  private dismissCard(): void {
    if (!this.cardVisible) {
      return
    }
    this.selectedId = ''
    this.draw()
    animateTo({ duration: 200, curve: Curve.EaseIn }, () => {
      this.cardOffset = 420
    })
    // 等退场动画走完再卸载卡片内容，否则文字会先消失、只剩空壳下滑
    setTimeout(() => {
      this.cardVisible = false
      this.cardItem = undefined
    }, 220)
  }

  // ---------------------------------------------------------------- 视图

  @Builder
  eraChip(era: string) {
    Text(`${era} ${this.countOf(era)}`)
      .fontSize(AppFont.caption)
      .fontColor(this.selectedEra === era ? AppColor.surface : AppColor.textSecondary)
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .backgroundColor(this.selectedEra === era ? AppColor.primary : AppColor.surface)
      .borderRadius(14)
      .borderWidth(1)
      .borderColor(this.selectedEra === era ? AppColor.primary : AppColor.divider)
      .onClick(() => {
        this.selectEra(era)
      })
  }

  @Builder
  detailCard(item: HeritageSummary) {
    Row({ space: 12 }) {
      if (item.cover.length > 0) {
        Image($rawfile(item.cover))
          .width(96)
          .height(96)
          .borderRadius(10)
          .objectFit(ImageFit.Cover)
          .backgroundColor('#EFE7DA')
      } else {
        Column()
          .width(96)
          .height(96)
          .borderRadius(10)
          .backgroundColor('#EFE7DA')
      }

      Column({ space: 5 }) {
        Text(item.name)
          .fontSize(AppFont.heading)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        Text(`${item.city} · ${item.era}${item.types.length > 0 ? ` · ${item.types[0]}` : ''}`)
          .fontSize(AppFont.caption)
          .fontColor(AppColor.primary)
          .width('100%')

        Text(item.summary)
          .fontSize(12)
          .fontColor(AppColor.textSecondary)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .lineHeight(18)
          .width('100%')

        Text('查看档案 ›')
          .fontSize(AppFont.caption)
          .fontColor(AppColor.primary)
          .width('100%')
          .textAlign(TextAlign.End)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding(12)
    .backgroundColor(AppColor.surface)
    .borderRadius(14)
    .shadow({ radius: 16, color: 'rgba(60, 40, 20, 0.14)', offsetY: 4 })
    .onClick(() => {
      this.openDetail(item.id)
    })
  }

  private openDetail(id: string): void {
    router.pushUrl({ url: 'pages/DetailPage', params: { id } })
  }

  build() {
    Column() {
      Column({ space: 3 }) {
        Text('黄河图志')
          .fontSize(AppFont.title)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
        Text(`河南段黄河文化遗产 ｜ 已收录 ${this.total} 处 ｜ 点击圆点查看`)
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textTertiary)
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding, top: 14, bottom: 10 })

      Scroll() {
        Row({ space: 8 }) {
          this.eraChip(ALL_ERAS)
          ForEach(
            ['仰韶', '龙山', '夏商', '周', '汉唐', '宋'],
            (era: string) => {
              this.eraChip(era)
            },
            (era: string) => era
          )
        }
        .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .height(44)

      if (this.loading) {
        Column() {
          Text('正在导入离线档案…')
            .fontSize(AppFont.body)
            .fontColor(AppColor.textSecondary)
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.error.length > 0) {
        Column() {
          Text(this.error)
            .fontSize(AppFont.body)
            .fontColor('#B3261E')
            .textAlign(TextAlign.Center)
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .padding(AppSize.pagePadding)
      } else {
        Stack({ alignContent: Alignment.Bottom }) {
          Canvas(this.ctx)
            .width('100%')
            .height('100%')
            .onReady(() => {
              this.ready = true
              this.draw()
            })
            .onClick((event: ClickEvent) => {
              this.handleTap(event.x, event.y)
            })

          if (this.items.length === 0) {
            Column() {
              Text(`${this.selectedEra}时期暂无收录`)
                .fontSize(AppFont.body)
                .fontColor(AppColor.textTertiary)
            }
            .width('100%')
            .height('100%')
            .justifyContent(FlexAlign.Center)
          }

          if (this.cardVisible && this.cardItem !== undefined) {
            Column() {
              this.detailCard(this.cardItem)
            }
            .width('100%')
            .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding, bottom: 14 })
            .translate({ y: this.cardOffset })
          }
        }
        .layoutWeight(1)
        .width('100%')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppColor.background)
  }
}
