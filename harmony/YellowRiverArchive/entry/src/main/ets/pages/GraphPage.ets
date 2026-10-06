import { common } from '@kit.AbilityKit'
import { router } from '@kit.ArkUI'

import type { GraphEdge, GraphNode } from '../shared'
import { AppColor, AppFont, AppSize } from '../constants/Theme'
import { GraphDao } from '../service/GraphDao'
import { ForceLayout, SimEdge, SimNode } from '../utils/ForceLayout'

/** 节点类型配色：同类同色，一眼能看出结构 */
const TYPE_COLORS: Map<string, string> = new Map<string, string>([
  ['Site', '#8C3B1E'],
  ['Artifact', '#C77B3A'],
  ['Era', '#5B7C99'],
  ['City', '#7A8B6F'],
  ['Type', '#9B7BA8'],
  ['Figure', '#B5885A'],
  ['Event', '#8A8A6B'],
  ['Poem', '#A8826B'],
  ['Museum', '#6E7B8B'],
])

function colorOf(type: string): string {
  const color: string | undefined = TYPE_COLORS.get(type)
  return color !== undefined ? color : '#9A9086'
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

  private draw(): void {
    const w: number = this.ctx.width
    const h: number = this.ctx.height
    this.ctx.clearRect(0, 0, w, h)

    const hasSelection: boolean = this.selected >= 0
    const highlighted: number[] = hasSelection
      ? this.neighbors.get(this.selected) ?? []
      : []

    // ---- 连边 ----
    for (const edge of this.layout.edges) {
      const a: SimNode | undefined = this.layout.nodes[edge.from]
      const b: SimNode | undefined = this.layout.nodes[edge.to]
      if (a === undefined || b === undefined) {
        continue
      }
      const touches: boolean =
        !hasSelection || edge.from === this.selected || edge.to === this.selected
      this.ctx.beginPath()
      this.ctx.moveTo(a.x, a.y)
      this.ctx.lineTo(b.x, b.y)
      this.ctx.lineWidth = touches && hasSelection ? 1.6 : 0.8
      this.ctx.strokeStyle = touches ? '#C4B7A6' : '#E6DED2'
      this.ctx.stroke()
    }

    // ---- 节点 ----
    this.layout.nodes.forEach((node, index) => {
      const isSelected: boolean = index === this.selected
      const isNeighbor: boolean = highlighted.includes(index)
      const dimmed: boolean = hasSelection && !isSelected && !isNeighbor

      const r: number = node.radius() * (isSelected ? 1.35 : 1)
      this.ctx.beginPath()
      this.ctx.arc(node.x, node.y, r, 0, Math.PI * 2)
      this.ctx.fillStyle = dimmed ? '#D8CFC3' : colorOf(node.type)
      this.ctx.fill()

      if (isSelected) {
        this.ctx.lineWidth = 3
        this.ctx.strokeStyle = AppColor.surface
        this.ctx.stroke()
      }

      // 只给重要节点与选中邻居画标签 —— 全画会糊成一片
      const showLabel: boolean = isSelected || isNeighbor || (!hasSelection && node.weight > 0.55)
      if (showLabel) {
        this.ctx.font = isSelected ? '13px sans-serif' : '11px sans-serif'
        this.ctx.fillStyle = dimmed ? '#B5AA9C' : AppColor.textPrimary
        this.ctx.fillText(node.name, node.x + r + 3, node.y + 4)
      }
    })
  }

  private onTap(x: number, y: number): void {
    if (this.layout.nodes.length === 0) {
      return
    }
    const hit: number = this.layout.hitTest(x, y)
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
