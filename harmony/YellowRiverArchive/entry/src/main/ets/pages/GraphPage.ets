import { common } from '@kit.AbilityKit'
import { router } from '@kit.ArkUI'

import type { GraphEdge, GraphNode } from '../shared'
import { CORE_ERAS } from '../shared'
import { AppColor, AppFont, AppSize } from '../constants/Theme'
import { HeritageDao } from '../service/HeritageDao'
import { GraphDao } from '../service/GraphDao'
import { ForceLayout, SimEdge, SimNode } from '../utils/ForceLayout'

/**
 * 簇配色：每个遗址一族色，[遗址本体, 簇内成员]。
 *
 * 为什么不按节点类型配色（初版做法）：按类型配时，20 多个文物全是同一个橙色、
 * 10 多个时代全是同一个蓝色，颜色不携带任何「这几个节点是一伙的」信息，
 * 57 个点看过去就是一把彩色沙子。**按簇配色才能读出结构**。
 */
const CLUSTER_COLORS: string[][] = [
  ['#8C3B1E', '#C4835F'],
  ['#4E6E8A', '#8FA9BE'],
  ['#6B7C5E', '#A3B096'],
  ['#8A6A99', '#B79CC4'],
  ['#B0722F', '#D5A671'],
  ['#7A7568', '#B5B0A4'],
]

function clusterColor(clusterIndex: number, isSite: boolean): string {
  const pair: string[] = CLUSTER_COLORS[clusterIndex % CLUSTER_COLORS.length]
  return isSite ? pair[0] : pair[1]
}

/** 节点类型的中文名（长按选中时展示） */
const TYPE_LABELS: Map<string, string> = new Map<string, string>([
  ['Site', '遗址'],
  ['Artifact', '文物'],
  ['Era', '时代'],
  ['City', '城市'],
  ['Type', '类型'],
  ['Figure', '人物'],
  ['Event', '事件'],
  ['Poem', '诗词'],
  ['Museum', '博物馆'],
])

/**
 * 知识图谱：力导向布局 + 类型着色 + 权重定大小。
 *
 * 动画直接重绘 Canvas，**不走 @State** —— 60fps 下每秒 60 次状态更新会让
 * ArkUI 的 diff 成为瓶颈，而 Canvas 只是把像素画上去。实测 200 节点
 * 6.57ms/帧（D0-V），留足了余量。
 */
@Component
export struct GraphPage {
  @State loading: boolean = true
  @State nodeCount: number = 0
  @State edgeCount: number = 0
  @State selectedName: string = ''
  @State selectedType: string = ''
  @State selectedItemId: string = ''
  @State settled: boolean = false
  /** 时间轴联动（D6-3）：选中的时代，空串表示不过滤 */
  @State activeEra: string = ''

  private settings: RenderingContextSettings = new RenderingContextSettings(true)
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings)
  // 先用占位尺寸构造，onReady 时按真实画布重建 ——
  // 硬编码尺寸会让布局在一个比画布小的盒子里收敛，四周留一大片空白
  private layout: ForceLayout = new ForceLayout(360, 600)
  private layoutSized: boolean = false
  private ready: boolean = false
  private timer: number = -1
  private selected: number = -1
  /** 邻居索引：高亮邻居用，避免每帧重算 */
  private neighbors: Map<number, number[]> = new Map<number, number[]>()
  /** 时代 → 节点下标。时间轴联动用它把「时代」映射到画布上的节点集合 */
  private eraNodes: Map<string, number[]> = new Map<string, number[]>()
  /** 每个节点所属簇的序号（按遗址首次出现顺序），决定颜色 */
  private clusterOfNode: number[] = []
  // ---- 视图变换：布局坐标 → 屏幕坐标 ----
  // 两级缩放：fitScale 让整图恰好填满画布（不论 5 个还是 500 个节点），
  // zoom 是用户的双指缩放倍数，panX/panY 是拖动偏移。
  // 分开存是为了「缩放围绕图像中心」—— 若把两者揉成一个 scale，
  // 缩放基准点会随平移漂移，手感很怪。
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
      nodes.forEach((node, i) => {
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

      // 邻居表：选中节点后高亮它的邻居与连边
      for (const edge of this.layout.edges) {
        const a: number[] = this.neighbors.get(edge.from) ?? []
        a.push(edge.to)
        this.neighbors.set(edge.from, a)
        const b: number[] = this.neighbors.get(edge.to) ?? []
        b.push(edge.from)
        this.neighbors.set(edge.to, b)
      }

      // ---- 簇归属：多源 BFS，所有遗址同时向外扩散，谁最近归谁 ----
      // 初版是「每个遗址依次 BFS 两跳」，结果**第一个遗址把几乎所有节点都吞了** ——
      // 因为两跳足以覆盖别的遗址的文物。后果是全图只有一个簇，全部节点挤到一个点，
      // 自动缩放把这个点放大成了一个占满屏幕的巨型圆。
      // 多源 BFS 保证「最近者得」，各簇规模才均衡。
      const clusterIdOfNode: string[] = []
      this.layout.nodes.forEach(() => {
        clusterIdOfNode.push('')
      })
      const siteIndices: number[] = []
      this.layout.nodes.forEach((n, i) => {
        if (n.type === 'Site') {
          siteIndices.push(i)
        }
      })
      let frontier: number[] = []
      for (const siteIdx of siteIndices) {
        clusterIdOfNode[siteIdx] = this.layout.nodes[siteIdx].id
        frontier.push(siteIdx)
      }
      // 逐层扩散；已归属的节点视为已访问，先到的不再改
      for (let depth = 0; depth < 2 && frontier.length > 0; depth += 1) {
        const next: number[] = []
        for (const idx of frontier) {
          for (const nb of this.neighbors.get(idx) ?? []) {
            if (clusterIdOfNode[nb].length === 0) {
              clusterIdOfNode[nb] = clusterIdOfNode[idx]
              next.push(nb)
            }
          }
        }
        frontier = next
      }
      // 簇序号：按首次出现顺序编号，保证同一份数据每次打开配色一致
      const clusterOrder: string[] = []
      this.clusterOfNode = []
      this.layout.nodes.forEach((node, i) => {
        const cid: string = clusterIdOfNode[i].length > 0 ? clusterIdOfNode[i] : '__rest__'
        node.cluster = cid
        if (!clusterOrder.includes(cid)) {
          clusterOrder.push(cid)
        }
        this.clusterOfNode.push(clusterOrder.indexOf(cid))
      })

      // 时间轴联动：把每个时代映射到它包含的节点
      // Site 节点的 id 就是 itemId，直接查档案拿时代，再把这些节点连同
      // 同名 Era 节点一起归入该时代
      await HeritageDao.ready(context)
      this.layout.nodes.forEach((node, i) => {
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

      this.nodeCount = nodes.length
      this.edgeCount = this.layout.edges.length
      this.layout.seed()
    } catch (err) {
      this.nodeCount = 0
    }
    this.loading = false
  }

  private startLoop(): void {
    if (!this.ready || this.timer !== -1 || this.layout.nodes.length === 0) {
      return
    }
    this.timer = setInterval(() => {
      // 收敛后停止迭代，只保留重绘以响应点击 —— 省电，也让画面不抖
      if (this.layout.energy() > 0.6) {
        this.layout.step()
      } else if (!this.settled) {
        this.settled = true
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

  /** 计算包围盒并换算视图变换，使整图缩放居中到画布内 */
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
    // 留出 18% 边距：标签画在节点右侧，需要额外的水平空间
    const padX: number = w * 0.18
    const padY: number = h * 0.08
    // 上限 1.3：布局若因数据退化而收缩，自动缩放会把单个节点放大成巨型圆。
    // 可选「看不清」胜过「看不对」—— 宁可图小一点，也不要一张畸形的图。
    this.fitScale = Math.min(1.3, Math.min((w - padX * 2) / spanX, (h - padY * 2) / spanY))
    this.bboxCx = (minX + maxX) / 2
    this.bboxCy = (minY + maxY) / 2
  }

  private viewScale(): number {
    return this.fitScale * this.zoom
  }

  // 以「画布中心 + 拖动偏移」为基准做缩放，缩放感受才是围绕视线中心
  private sx(x: number): number {
    return (x - this.bboxCx) * this.viewScale() + this.ctx.width / 2 + this.panX
  }

  private sy(y: number): number {
    return (y - this.bboxCy) * this.viewScale() + this.ctx.height / 2 + this.panY
  }

  private draw(): void {
    const w: number = this.ctx.width
    const h: number = this.ctx.height
    this.ctx.clearRect(0, 0, w, h)
    this.fitView()

    const hasSelection: boolean = this.selected >= 0
    const highlighted: number[] = hasSelection
      ? this.neighbors.get(this.selected) ?? []
      : []
    // 时间轴联动：选中时代后，不属于该时代的节点淡出
    const eraSet: Set<number> = new Set<number>()
    if (this.activeEra.length > 0) {
      for (const i of this.eraNodes.get(this.activeEra) ?? []) {
        eraSet.add(i)
      }
    }
    const hasEraFilter: boolean = this.activeEra.length > 0

    // ---- 连边 ----
    for (const edge of this.layout.edges) {
      const a: SimNode | undefined = this.layout.nodes[edge.from]
      const b: SimNode | undefined = this.layout.nodes[edge.to]
      if (a === undefined || b === undefined) {
        continue
      }
      const touches: boolean =
        !hasSelection || edge.from === this.selected || edge.to === this.selected
      const inEra: boolean =
        !hasEraFilter || (eraSet.has(edge.from) && eraSet.has(edge.to))
      this.ctx.beginPath()
      this.ctx.moveTo(this.sx(a.x), this.sy(a.y))
      this.ctx.lineTo(this.sx(b.x), this.sy(b.y))
      this.ctx.lineWidth = touches && hasSelection ? 1.6 : 0.8
      this.ctx.strokeStyle = inEra ? (touches ? '#C4B7A6' : '#E6DED2') : '#F0EBE4'
      this.ctx.stroke()
    }

    // ---- 节点 ----
    this.layout.nodes.forEach((node, index) => {
      const isSelected: boolean = index === this.selected
      const isNeighbor: boolean = highlighted.includes(index)
      const eraDimmed: boolean = hasEraFilter && !eraSet.has(index)
      const dimmed: boolean = eraDimmed || (hasSelection && !isSelected && !isNeighbor)

      // 淡出用透明度而不是浅色 —— 浅色圆点仍占满画面，看起来就是一团噪声
      const isSiteNode: boolean = node.type === 'Site'
      const baseR: number = isSiteNode
        ? node.radius() * 1.5
        : Math.max(2.5, node.radius() * 0.62)
      const r: number = Math.max(2.5, baseR * this.viewScale()) * (isSelected ? 1.3 : 1)
      const nx: number = this.sx(node.x)
      const ny: number = this.sy(node.y)
      this.ctx.globalAlpha = dimmed ? 0.16 : 1
      this.ctx.beginPath()
      this.ctx.arc(nx, ny, r, 0, Math.PI * 2)
      this.ctx.fillStyle = clusterColor(this.clusterOfNode[index] ?? 0, node.type === 'Site')
      this.ctx.fill()

      if (isSelected) {
        this.ctx.lineWidth = 3
        this.ctx.strokeStyle = AppColor.surface
        this.ctx.stroke()
      }

      // 只给重要节点与选中邻居画标签 —— 全画会糊成一片
      // 遗址名永远显示（它是簇的锚点，读图全靠它定坐标）；
      // 成员名只在放大到 1.6 倍以上或选中相关时出现，避免拥挤
      const showLabel: boolean =
        isSelected ||
        isNeighbor ||
        isSiteNode ||
        (this.zoom >= 1.6 && node.weight > 0.35 && !eraDimmed)
      if (showLabel) {
        const fontSize: number = isSelected ? 14 : 12
        this.ctx.font = `${fontSize}px sans-serif`
        this.ctx.globalAlpha = dimmed ? 0.3 : 1
        const tx: number = nx + r + 4
        const ty: number = ny + fontSize / 2 - 1
        // 先描一圈背景色再加文字 —— 图密集时标签会压在连边与其他节点上，
        // 没有这层描边就完全读不出来
        this.ctx.lineWidth = 3
        this.ctx.strokeStyle = AppColor.surface
        this.ctx.strokeText(node.name, tx, ty)
        this.ctx.fillStyle = AppColor.textPrimary
        this.ctx.fillText(node.name, tx, ty)
      }
      this.ctx.globalAlpha = 1
    })
  }

  private onTap(x: number, y: number): void {
    if (this.layout.nodes.length === 0) {
      return
    }
    // 点击坐标是屏幕坐标，先反算回布局坐标再命中测试
    const scale: number = this.viewScale() > 0 ? this.viewScale() : 1
    const lx: number = (x - this.ctx.width / 2 - this.panX) / scale + this.bboxCx
    const ly: number = (y - this.ctx.height / 2 - this.panY) / scale + this.bboxCy
    // 命中半径按屏幕像素给，换算到布局坐标要除以缩放
    const hit: number = this.layout.hitTest(lx, ly, 26 / scale)
    if (hit === this.selected) {
      return
    }
    this.selected = hit
    if (hit >= 0) {
      const node: SimNode = this.layout.nodes[hit]
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

  build() {
    Column() {
      Row() {
        Text('知识图谱')
          .fontSize(AppFont.title)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
          .layoutWeight(1)
        // 缩放按钮：双指手势不易被发现，且 CLI 无法模拟双指 ——
        // 给一组显式按钮，既好发现也好验证
        Text('−')
          .fontSize(16)
          .fontColor(this.zoom > 1.02 ? AppColor.primary : AppColor.textTertiary)
          .padding({ left: 8, right: 8 })
          .onClick(() => {
            this.zoom = Math.max(1, this.zoom / 1.5)
            if (this.zoom <= 1.02) {
              this.panX = 0
              this.panY = 0
            }
            this.draw()
          })
        Text('+')
          .fontSize(16)
          .fontColor(this.zoom < 4.9 ? AppColor.primary : AppColor.textTertiary)
          .padding({ left: 8, right: 8 })
          .onClick(() => {
            this.zoom = Math.min(5, this.zoom * 1.5)
            this.draw()
          })
        if (this.zoom > 1.02 || Math.abs(this.panX) > 2 || Math.abs(this.panY) > 2) {
          Text('复位')
            .fontSize(11)
            .fontColor(AppColor.primary)
            .margin({ right: 10 })
            .onClick(() => {
              this.zoom = 1
              this.panX = 0
              this.panY = 0
              this.draw()
            })
        }
        Text(`${this.nodeCount} 节点 · ${this.edgeCount} 连边`)
          .fontSize(11)
          .fontColor(AppColor.textTertiary)
      }
      .width('100%')
      .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding, top: 16, bottom: 8 })

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
          .backgroundColor(AppColor.surface)
          .onReady(() => {
            this.ready = true
            // 画布尺寸在 onReady 才可知；按真实尺寸重建布局并重新撒点后再启动动画
            if (!this.layoutSized && this.ctx.width > 0 && this.ctx.height > 0) {
              this.layoutSized = true
              const rebuilt: ForceLayout = new ForceLayout(this.ctx.width, this.ctx.height)
              for (const node of this.layout.nodes) {
                rebuilt.nodes.push(node)
              }
              for (const edge of this.layout.edges) {
                rebuilt.edges.push(edge)
              }
              rebuilt.seed()
              this.layout = rebuilt
            }
            this.startLoop()
          })
          .onClick((event: ClickEvent) => {
            this.onTap(event.x, event.y)
          })
          // 双指缩放 + 单指拖动。与 onClick 并行：位移小于手势阈值时
          // 仍判定为点击，所以「轻点选中 / 拖拽平移」不会互相打架
          .gesture(
            GestureGroup(
              GestureMode.Parallel,
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
                  this.zoom = Math.max(1, Math.min(5, this.zoomStart * event.scale))
                  this.draw()
                })
            )
          )
      }

      // 时代轴：点选高亮该时代的节点（D6-3）
      if (this.nodeCount > 0) {
        Scroll() {
          Row({ space: 8 }) {
            ForEach(
              CORE_ERAS,
              (era: string) => {
                Text(era)
                  .fontSize(11)
                  .fontColor(this.activeEra === era ? AppColor.surface : AppColor.textSecondary)
                  .backgroundColor(this.activeEra === era ? AppColor.primary : AppColor.background)
                  .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                  .borderRadius(12)
                  .onClick(() => {
                    this.activeEra = this.activeEra === era ? '' : era
                    this.draw()
                  })
              },
              (era: string) => era
            )
          }
          .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        .padding({ top: 6, bottom: 6 })
      }

      // 选中详情条：点节点看名称与类型，Site 节点可直接进详情
      if (this.selectedName.length > 0) {
        Row({ space: 10 }) {
          Column({ space: 2 }) {
            Text(this.selectedName)
              .fontSize(AppFont.body)
              .fontColor(AppColor.textPrimary)
              .width('100%')
            Text(this.selectedType)
              .fontSize(11)
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
        .backgroundColor(AppColor.background)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppColor.background)
  }
}
