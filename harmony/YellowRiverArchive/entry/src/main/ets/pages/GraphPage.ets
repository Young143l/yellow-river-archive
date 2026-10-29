import { common } from '@kit.AbilityKit'
import { router } from '@kit.ArkUI'

import type { GraphEdge, GraphNode } from '../shared'
import { CORE_ERAS } from '../shared'
import { AppColor, AppFont, AppSize, FontFamily } from '../constants/Theme'
import { GraphDao } from '../service/GraphDao'
import { HeritageDao } from '../service/HeritageDao'
import { ForceLayout, SimEdge, SimNode } from '../utils/ForceLayout'

/**
 * 节点配色：按类型分。
 *
 * 用全站那套矿物色 —— 让它和首页的河、朱砂印是同一个色谱，
 * 而不是另起一套"数据可视化配色"。遗址取朱砂（最重要），
 * 文物取赭石、事件取石绿、人物取石青，正好都在河流与印章的色域里。
 */
const TYPE_COLORS: Map<string, string> = new Map<string, string>([
  ['Site', '#A2392B'],
  ['Artifact', '#B5813F'],
  ['Event', '#5E8A6B'],
  ['Figure', '#3D7288'],
  ['Poem', '#7A6A94'],
  ['Museum', '#B8912F'],
  ['Era', '#6E838C'],
  ['City', '#7A8790'],
  ['Type', '#98A3AB'],
])

const TYPE_LABELS: Map<string, string> = new Map<string, string>([
  ['Site', '遗址'],
  ['Artifact', '文物'],
  ['Event', '事件'],
  ['Figure', '人物'],
  ['Poem', '诗词'],
  ['Museum', '博物馆'],
  ['Era', '时代'],
  ['City', '城市'],
  ['Type', '类型'],
])

/** 图例顺序：按重要性排，不是按字母 */
const LEGEND_TYPES: string[] = [
  'Site', 'Artifact', 'Event', 'Figure', 'Poem', 'Museum', 'Era', 'City', 'Type',
]

function colorOf(type: string): string {
  const c: string | undefined = TYPE_COLORS.get(type)
  return c !== undefined ? c : '#98A3AB'
}

/**
 * 知识图谱。
 *
 * 视觉规则参照 Obsidian 的图谱：
 *   - 节点是**小圆点**，没有描边、没有大圆饼
 *   - 连边**极细极淡**，不与节点抢视觉重量
 *   - **默认不显示标签**，选中节点及其邻居才出字
 *   - 缩放后才逐步放出更多标签
 *
 * 这些规则的共同目的是：先让人看见"结构"，再让人读"内容"。
 * 之前把标签全铺开、节点画成大圆，结构就淹没在文字里了。
 *
 * 底色仍用宣纸而非 Obsidian 的深色 —— 全站是暖纸 + 矿物色，
 * 单独一页换成深底会脱节。
 */
@Component
export struct GraphPage {
  @State loading: boolean = true
  @State nodeCount: number = 0
  @State edgeCount: number = 0
  @State selectedName: string = ''
  @State selectedType: string = ''
  @State selectedItemId: string = ''
  @State zoomLevel: number = 1
  @State activeEra: string = ''

  private settings: RenderingContextSettings = new RenderingContextSettings(true)
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings)
  private layout: ForceLayout = new ForceLayout(360, 600)
  private ready: boolean = false
  private timer: number = -1
  private selected: number = -1
  private neighbors: Map<number, number[]> = new Map<number, number[]>()
  private eraNodes: Map<string, number[]> = new Map<string, number[]>()

  /** 视图变换：fitScale 自适配，zoom/pan 由用户控制 */
  private fitScale: number = 1
  private bboxCx: number = 0
  private bboxCy: number = 0
  private zoom: number = 1
  private zoomStart: number = 1
  private panX: number = 0
  private panY: number = 0
  private panStartX: number = 0
  private panStartY: number = 0

  aboutToAppear(): void {
    this.load()
  }

  aboutToDisappear(): void {
    this.stopLoop()
  }

  private async load(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.Context
      const nodes: GraphNode[] = await GraphDao.nodes(context)
      const edges: GraphEdge[] = await GraphDao.edges(context)

      const indexOf = new Map<string, number>()
      nodes.forEach((node: GraphNode, i: number) => {
        indexOf.set(node.id, i)
        const weight: number = node.rank !== undefined ? node.rank : 0
        this.layout.nodes.push(new SimNode(node.id, node.name, node.type, weight))
      })

      for (const edge of edges) {
        const from: number | undefined = indexOf.get(edge.from)
        const to: number | undefined = indexOf.get(edge.to)
        if (from !== undefined && to !== undefined) {
          this.layout.edges.push(new SimEdge(from, to, edge.weight))
        }
      }

      for (const edge of this.layout.edges) {
        const a: number[] = this.neighbors.get(edge.from) ?? []
        a.push(edge.to)
        this.neighbors.set(edge.from, a)
        const b: number[] = this.neighbors.get(edge.to) ?? []
        b.push(edge.from)
        this.neighbors.set(edge.to, b)
      }

      this.buildClusters()
      await this.buildEraIndex(context)

      this.nodeCount = nodes.length
      this.edgeCount = this.layout.edges.length
      this.layout.seed()
    } catch (err) {
      this.nodeCount = 0
    }
    this.loading = false
    if (this.ready && this.ctx.width > 0) {
      this.draw()
    }
  }

  /**
   * 簇归属：多源 BFS，所有遗址同时向外扩散，最近者归谁。
   *
   * 不能用「每个遗址依次 BFS」—— 两跳足以覆盖别的遗址的文物，
   * 第一个遗址会吞掉整张图，结果只剩一个簇。
   */
  private buildClusters(): void {
    const clusterOf: string[] = []
    this.layout.nodes.forEach(() => {
      clusterOf.push('')
    })
    let frontier: number[] = []
    this.layout.nodes.forEach((n: SimNode, i: number) => {
      if (n.type === 'Site') {
        clusterOf[i] = n.id
        frontier.push(i)
      }
    })
    for (let depth = 0; depth < 2 && frontier.length > 0; depth += 1) {
      const next: number[] = []
      for (const idx of frontier) {
        for (const nb of this.neighbors.get(idx) ?? []) {
          if (clusterOf[nb].length === 0) {
            clusterOf[nb] = clusterOf[idx]
            next.push(nb)
          }
        }
      }
      frontier = next
    }
    this.layout.nodes.forEach((node: SimNode, i: number) => {
      node.cluster = clusterOf[i].length > 0 ? clusterOf[i] : '__rest__'
    })
  }

  private async buildEraIndex(context: common.Context): Promise<void> {
    await HeritageDao.ready(context)
    this.layout.nodes.forEach((node: SimNode, i: number) => {
      let era: string = ''
      if (node.type === 'Site') {
        const item = HeritageDao.detail(node.id)
        if (item !== undefined) {
          era = item.era
        }
      } else if (node.type === 'Era') {
        era = node.name
      }
      if (era.length === 0) {
        return
      }
      const bucket: number[] = this.eraNodes.get(era) ?? []
      bucket.push(i)
      this.eraNodes.set(era, bucket)
    })
  }

  private startLoop(): void {
    if (!this.ready || this.timer !== -1 || this.layout.nodes.length === 0) {
      return
    }
    this.timer = setInterval(() => {
      if (this.layout.energy() > 0.6) {
        this.layout.step()
      }
      this.draw()
    }, 16)
  }

  private stopLoop(): void {
    if (this.timer !== -1) {
      clearInterval(this.timer)
      this.timer = -1
    }
  }

  // ---------------------------------------------------------------- 视图变换

  private fitView(): void {
    const w: number = this.ctx.width
    const h: number = this.ctx.height
    if (this.layout.nodes.length === 0 || w <= 0 || h <= 0) {
      return
    }
    let minX: number = Number.MAX_VALUE
    let maxX: number = -Number.MAX_VALUE
    let minY: number = Number.MAX_VALUE
    let maxY: number = -Number.MAX_VALUE
    for (const node of this.layout.nodes) {
      minX = Math.min(minX, node.x - node.radius())
      maxX = Math.max(maxX, node.x + node.radius())
      minY = Math.min(minY, node.y - node.radius())
      maxY = Math.max(maxY, node.y + node.radius())
    }
    const spanX: number = Math.max(1, maxX - minX)
    const spanY: number = Math.max(1, maxY - minY)
    const pad: number = w * 0.08
    this.fitScale = Math.min(1.35, Math.min((w - pad * 2) / spanX, (h - pad * 2) / spanY))
    this.bboxCx = (minX + maxX) / 2
    // 纵向补偿 8%：图看起来偏下，是因为 bbox 含节点半径、且上方图例区占了视觉重量。
    // 这里直接给一点上移量，让图在可视区里居中。
    this.bboxCy = (minY + maxY) / 2 - spanY * 0.08
  }

  private viewScale(): number {
    return this.fitScale * this.zoom
  }

  private sx(x: number): number {
    return (x - this.bboxCx) * this.viewScale() + this.ctx.width / 2 + this.panX
  }

  private sy(y: number): number {
    return (y - this.bboxCy) * this.viewScale() + this.ctx.height / 2 + this.panY
  }

  // ---------------------------------------------------------------- 绘制

  private draw(): void {
    const w: number = this.ctx.width
    const h: number = this.ctx.height
    if (w <= 0 || h <= 0) {
      return
    }
    this.ctx.clearRect(0, 0, w, h)
    this.fitView()

    const hasSelection: boolean = this.selected >= 0
    const highlighted: number[] = hasSelection ? this.neighbors.get(this.selected) ?? [] : []
    const eraSet: Set<number> = new Set<number>()
    if (this.activeEra.length > 0) {
      for (const i of this.eraNodes.get(this.activeEra) ?? []) {
        eraSet.add(i)
      }
    }
    const hasEra: boolean = this.activeEra.length > 0

    // ---- 连边：极细极淡 ----
    // Obsidian 的连杆是 0.3 倍线宽，几乎只是一层灰雾。
    // 连边一旦画实，整张图就变成一团网，节点反而看不见。
    for (const edge of this.layout.edges) {
      const a: SimNode | undefined = this.layout.nodes[edge.from]
      const b: SimNode | undefined = this.layout.nodes[edge.to]
      if (a === undefined || b === undefined) {
        continue
      }
      const touches: boolean =
        !hasSelection || edge.from === this.selected || edge.to === this.selected
      const inEra: boolean = !hasEra || (eraSet.has(edge.from) && eraSet.has(edge.to))

      this.ctx.beginPath()
      this.ctx.moveTo(this.sx(a.x), this.sy(a.y))
      this.ctx.lineTo(this.sx(b.x), this.sy(b.y))
      this.ctx.lineWidth = touches && hasSelection ? 1.7 : 1.0
      this.ctx.strokeStyle = !inEra
        ? 'rgba(200, 208, 210, 0.18)'
        : (touches && hasSelection ? 'rgba(80, 112, 126, 0.62)' : 'rgba(140, 162, 172, 0.48)')
      this.ctx.stroke()
    }

    // ---- 节点 ----
    this.layout.nodes.forEach((node: SimNode, index: number) => {
      const isSelected: boolean = index === this.selected
      const isNeighbor: boolean = highlighted.includes(index)
      const eraDim: boolean = hasEra && !eraSet.has(index)
      const dim: boolean = eraDim || (hasSelection && !isSelected && !isNeighbor)

      // 手机端节点不能按桌面的尺度来 —— 3px 的点在手机上基本是灰尘。
      // 遗址 8–11，其余 4–7.5；选中再放大一半。
      const isSite: boolean = node.type === 'Site'
      const baseR: number = isSite ? 8 + node.weight * 3 : 4 + node.weight * 3.5
      const r: number = Math.max(3.4, baseR * this.viewScale()) * (isSelected ? 1.45 : 1)
      const nx: number = this.sx(node.x)
      const ny: number = this.sy(node.y)

      this.ctx.globalAlpha = dim ? 0.18 : 1

      // 遗址节点带一点同色辉光，把视线引到「这几处是主干」
      if (isSite && !dim) {
        this.ctx.shadowBlur = 14
        this.ctx.shadowColor = colorOf(node.type)
      }

      this.ctx.beginPath()
      this.ctx.arc(nx, ny, r, 0, Math.PI * 2)
      this.ctx.fillStyle = colorOf(node.type)
      this.ctx.fill()
      this.ctx.shadowBlur = 0

      if (isSelected) {
        this.ctx.beginPath()
        this.ctx.arc(nx, ny, r + 3.5, 0, Math.PI * 2)
        this.ctx.lineWidth = 1.4
        this.ctx.strokeStyle = colorOf(node.type)
        this.ctx.stroke()
      }

      // 标签：默认不显示。只有选中项、其邻居、遗址节点，或放大到 1.6 倍以上才出字。
      const showLabel: boolean =
        isSelected || isNeighbor || isSite || (this.viewScale() > 1.45 && !eraDim)
      if (showLabel) {
        const fs: number = isSelected ? 16 : (isSite ? 14 : 12)
        this.ctx.font = `${fs}px sans-serif`
        this.ctx.textAlign = 'left'
        const tx: number = nx + r + 5
        const ty: number = ny + fs * 0.36
        this.ctx.globalAlpha = dim ? 0.25 : 1
        // 描一圈纸色再写字：图密集时标签会压在连边与其他节点上
        this.ctx.lineWidth = 3.5
        this.ctx.strokeStyle = AppColor.background
        this.ctx.strokeText(node.name, tx, ty)
        this.ctx.fillStyle = AppColor.textPrimary
        this.ctx.fillText(node.name, tx, ty)
      }
      this.ctx.globalAlpha = 1
    })
  }

  // ---------------------------------------------------------------- 交互

  /**
   * 命中测试：**直接在屏幕坐标里比距离**。
   *
   * 不走「屏幕 → 布局」的反算。反算要依赖 bbox、fitScale、pan 三者，
   * 任何一项对不上就静默失败（实测点击无效且没有任何报错）。
   * 而绘制本身就用了 sx/sy 得到节点的屏幕位置，
   * 拿点击点直接和这些屏幕位置比，就不存在换算错位的可能。
   */
  private onTap(x: number, y: number): void {
    if (this.layout.nodes.length === 0) {
      return
    }
    let best: number = -1
    let bestD2: number = 26 * 26
    this.layout.nodes.forEach((node: SimNode, i: number) => {
      const dx: number = this.sx(node.x) - x
      const dy: number = this.sy(node.y) - y
      const d2: number = dx * dx + dy * dy
      if (d2 < bestD2) {
        bestD2 = d2
        best = i
      }
    })
    if (best === this.selected) {
      return
    }
    this.selected = best
    if (best >= 0) {
      const node: SimNode = this.layout.nodes[best]
      this.selectedName = node.name
      const label: string | undefined = TYPE_LABELS.get(node.type)
      this.selectedType = label !== undefined ? label : node.type
      this.selectedItemId = node.type === 'Site' ? node.id : ''
    } else {
      this.selectedName = ''
      this.selectedType = ''
      this.selectedItemId = ''
    }
    this.draw()
  }

  private setZoom(next: number): void {
    this.zoom = Math.max(0.7, Math.min(3.2, next))
    if (this.zoom <= 1.02) {
      this.panX = 0
      this.panY = 0
    }
    this.zoomLevel = this.zoom
    this.draw()
  }

  // ---------------------------------------------------------------- 视图

  /**
   * 图例：两行换行，不再横向滚动。
   *
   * 原先的横滚把右侧「城市」「类型」裁在屏幕外，也没有任何提示，
   * 看起来像渲染出错。图例是读图的前提，必须一眼看全。
   */
  @Builder
  legend() {
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(
        LEGEND_TYPES,
        (t: string) => {
          Row({ space: 4 }) {
            Column()
              .width(8)
              .height(8)
              .borderRadius(4)
              .backgroundColor(colorOf(t))
            Text(TYPE_LABELS.get(t) !== undefined ? TYPE_LABELS.get(t) : t)
              .fontSize(11)
              .fontColor(AppColor.textTertiary)
          }
          .margin({ right: 12, bottom: 4 })
        },
        (t: string) => t
      )
    }
    .width('100%')
    .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding, bottom: 2 })
  }

  /** 时代筛选：换行排布，保证「宋」不被裁掉 */
  @Builder
  eraBar() {
    Flex({ wrap: FlexWrap.Wrap }) {
      Text('全部')
        .fontSize(11)
        .fontColor(this.activeEra.length === 0 ? AppColor.surface : AppColor.textSecondary)
        .backgroundColor(this.activeEra.length === 0 ? AppColor.primary : AppColor.surface)
        .padding({ left: 10, right: 10, top: 5, bottom: 5 })
        .borderRadius(12)
        .borderWidth(1)
        .borderColor(this.activeEra.length === 0 ? AppColor.primary : AppColor.divider)
        .margin({ right: 7, bottom: 5 })
        .onClick(() => {
          this.activeEra = ''
          this.draw()
        })
      ForEach(
        CORE_ERAS,
        (era: string) => {
          Text(era)
            .fontSize(11)
            .fontColor(this.activeEra === era ? AppColor.surface : AppColor.textSecondary)
            .backgroundColor(this.activeEra === era ? AppColor.primary : AppColor.surface)
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .borderRadius(12)
            .borderWidth(1)
            .borderColor(this.activeEra === era ? AppColor.primary : AppColor.divider)
            .margin({ right: 7, bottom: 5 })
            .onClick(() => {
              this.activeEra = this.activeEra === era ? '' : era
              this.draw()
            })
        },
        (era: string) => era
      )
    }
    .width('100%')
    .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding, bottom: 4 })
  }

  build() {
    Column() {
      Row() {
        Text('知识图谱')
          .fontSize(22)
          .fontFamily(FontFamily.serifBold)
          .fontColor(AppColor.textPrimary)
          .letterSpacing(3)
          .layoutWeight(1)
        Text('−')
          .fontSize(16)
          .fontColor(this.zoom > 1.02 ? AppColor.primary : AppColor.textTertiary)
          .padding({ left: 8, right: 8 })
          .onClick(() => {
            this.setZoom(this.zoom / 1.5)
          })
        Text('+')
          .fontSize(16)
          .fontColor(this.zoom < 3.1 ? AppColor.primary : AppColor.textTertiary)
          .padding({ left: 8, right: 8 })
          .onClick(() => {
            this.setZoom(this.zoom * 1.5)
          })
        if (this.zoom > 1.02) {
          Text('复位')
            .fontSize(11)
            .fontColor(AppColor.primary)
            .onClick(() => {
              this.setZoom(1)
            })
        }
      }
      .width('100%')
      .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding, top: 14, bottom: 6 })

      Text(`${this.nodeCount} 节点 · ${this.edgeCount} 连边`)
        .fontSize(10)
        .fontColor(AppColor.textTertiary)
        .width('100%')
        .padding({ left: AppSize.pagePadding, bottom: 6 })

      this.legend()
      this.eraBar()

      if (this.loading) {
        Column() {
          Text('加载图谱…')
            .fontSize(AppFont.body)
            .fontColor(AppColor.textSecondary)
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.nodeCount === 0) {
        Column() {
          Text('图谱数据为空')
            .fontSize(AppFont.body)
            .fontColor(AppColor.textSecondary)
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else {
        Canvas(this.ctx)
          .width('100%')
          .layoutWeight(1)
          .backgroundColor(AppColor.background)
          .onReady(() => {
            this.ready = true
            this.draw()
            this.startLoop()
          })
          // 点击必须走 TapGesture，不能用 onClick：
          // 组件一旦挂了 GestureGroup，onClick 会被手势链吞掉（实测日志里
          // onTap 一次都没进）。把 Tap 也放进同一个手势组里才能共存。
          .gesture(
            GestureGroup(
              GestureMode.Parallel,
              TapGesture({ count: 1 })
                .onAction((event: GestureEvent) => {
                  if (event.fingerList.length > 0) {
                    this.onTap(event.fingerList[0].localX, event.fingerList[0].localY)
                  }
                }),
              PanGesture({ fingers: 1, distance: 8 })
                .onActionStart(() => {
                  this.panStartX = this.panX
                  this.panStartY = this.panY
                })
                .onActionUpdate((event: GestureEvent) => {
                  this.panX = this.panStartX + event.offsetX
                  this.panY = this.panStartY + event.offsetY
                  this.draw()
                }),
              PinchGesture({ fingers: 2 })
                .onActionStart(() => {
                  this.zoomStart = this.zoom
                })
                .onActionUpdate((event: GestureEvent) => {
                  this.setZoom(this.zoomStart * event.scale)
                })
            )
          )
      }

      if (this.selectedName.length > 0) {
        Row({ space: 10 }) {
          Column()
            .width(8)
            .height(8)
            .borderRadius(4)
            .backgroundColor(
              this.selected >= 0 && this.selected < this.layout.nodes.length
                ? colorOf(this.layout.nodes[this.selected].type)
                : AppColor.textTertiary
            )
          Column({ space: 2 }) {
            Text(this.selectedName)
              .fontSize(AppFont.caption)
              .fontColor(AppColor.textPrimary)
              .width('100%')
            Text(this.selectedType)
              .fontSize(10)
              .fontColor(AppColor.textTertiary)
              .width('100%')
          }
          .layoutWeight(1)

          if (this.selectedItemId.length > 0) {
            Text('查看档案')
              .fontSize(AppFont.caption)
              .fontColor(AppColor.primary)
              .onClick(() => {
                router.pushUrl({ url: 'pages/DetailPage', params: { id: this.selectedItemId } })
              })
          }
        }
        .width('100%')
        .padding(AppSize.pagePadding)
        .backgroundColor(AppColor.surface)
        .borderWidth({ top: 1 })
        .borderColor({ top: AppColor.divider })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppColor.background)
  }
}
