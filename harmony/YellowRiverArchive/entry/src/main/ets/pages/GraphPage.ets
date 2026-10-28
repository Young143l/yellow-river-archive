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
  /**
   * 聚焦的遗址序号，-1 表示显示全图。
   *
   * 默认聚焦 —— 参照 Obsidian 的局部图谱：手机上把 57 个节点塞进一屏，
   * 无论怎么调布局都读不出来。**聚焦一个遗址、只画它和它的一跳邻居**，
   * 邻居沿圆周均匀排布，没有物理模拟、没有重叠、永远可读。
   */
  @State focusSite: number = -1

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
  /** 各遗址节点在 layout.nodes 中的下标（@State 才能驱动遗址切换条重绘） */
  @State siteIndices: number[] = []
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
      this.siteIndices = siteIndices
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
    // 数据到位后再应用一次聚焦布局。
    // onReady 早于数据加载完成，那时 nodes 还是空的，applyFocusLayout 会走
    // 「全图」分支；不在加载完成后补一次，默认聚焦就永远不生效。
    if (this.ready && this.ctx.width > 0) {
      this.applyFocusLayout()
      this.draw()
    }
  }

  /**
   * 径向自我网络布局：焦点放中心，一跳邻居沿圆周均匀排布。
   *
   * 这是移动端图谱的标准做法（Obsidian 局部图谱、D3 radial tree 同理）：
   * 节点数固定在十几个，位置可解析计算 —— 不需要物理模拟，
   * 不会重叠，也不需要用户缩放才能看清。
   */
  private applyFocusLayout(): void {
    const w: number = this.ctx.width
    const h: number = this.ctx.height
    if (w <= 0 || h <= 0) {
      return
    }
    this.layout.nodes.forEach((node) => {
      node.hidden = true
    })

    const focusIdx: number = this.focusSite
    if (focusIdx < 0 || focusIdx >= this.layout.nodes.length) {
      // 全图模式：全部显示，交给力导向
      this.layout.nodes.forEach((node) => {
        node.hidden = false
      })
      this.layout.seed()
      return
    }

    const focus: SimNode = this.layout.nodes[focusIdx]
    focus.hidden = false
    focus.x = w / 2
    focus.y = h / 2

    // 一跳邻居按「同簇优先」排序后均匀排布，同类节点会相邻，读起来成组
    const neighborIdxs: number[] = (this.neighbors.get(focusIdx) ?? []).slice()
    neighborIdxs.sort((a, b) => {
      const ca: number = this.clusterOfNode[a] ?? 0
      const cb: number = this.clusterOfNode[b] ?? 0
      if (ca !== cb) {
        return ca - cb
      }
      return this.layout.nodes[a].name.localeCompare(this.layout.nodes[b].name)
    })

    const count: number = neighborIdxs.length
    // 半径留足边距，给外圈标签留出空间
    const radius: number = Math.min(w * 0.34, h * 0.30)
    neighborIdxs.forEach((idx: number, k: number) => {
      const node: SimNode = this.layout.nodes[idx]
      node.hidden = false
      // 从正上方开始顺时针排列，视觉上有确定的起点
      const theta: number = (Math.PI * 2 * k) / Math.max(1, count) - Math.PI / 2
      node.x = w / 2 + radius * Math.cos(theta)
      node.y = h / 2 + radius * Math.sin(theta)
    })

    // 二跳节点不显示，但保留在原位（切回全图时不用重新布局）
  }

  /** 切换聚焦的遗址 */
  private setFocus(siteOrder: number): void {
    this.focusSite = siteOrder
    this.zoom = 1
    this.panX = 0
    this.panY = 0
    this.applyFocusLayout()
    this.draw()
  }

  private startLoop(): void {
    if (!this.ready || this.timer !== -1 || this.layout.nodes.length === 0) {
      return
    }
    this.timer = setInterval(() => {
      // 聚焦模式下位置是解析算出来的，不需要迭代
      if (this.focusSite < 0) {
        if (this.layout.energy() > 0.6) {
          this.layout.step()
        } else if (!this.settled) {
          this.settled = true
        }
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
    // 聚焦模式下位置已按画布解析算好，再做自动适配只会把图缩小一圈
    if (this.focusSite >= 0) {
      this.fitScale = 1
      this.bboxCx = w / 2
      this.bboxCy = h / 2
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
    // 标签默认不显示后不再需要为它预留水平空间，边距收到 7%，
    // 让图铺满画布 —— 之前那 18% 让整张图只占了画布中间一小块
    const padX: number = w * 0.07
    const padY: number = h * 0.05
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
      if (a === undefined || b === undefined || a.hidden || b.hidden) {
        continue
      }
      const touches: boolean =
        !hasSelection || edge.from === this.selected || edge.to === this.selected
      const inEra: boolean =
        !hasEraFilter || (eraSet.has(edge.from) && eraSet.has(edge.to))
      this.ctx.beginPath()
      this.ctx.moveTo(this.sx(a.x), this.sy(a.y))
      this.ctx.lineTo(this.sx(b.x), this.sy(b.y))
      // Obsidian 风格：连边是极细极淡的辅助线，不该与节点抢视觉重量
      this.ctx.lineWidth = touches && hasSelection ? 1.2 : 0.6
      this.ctx.strokeStyle = touches && hasSelection ? '#B8AFA3' : '#DED8D0'
      this.ctx.stroke()
    }

    // ---- 节点 ----
    this.layout.nodes.forEach((node, index) => {
      if (node.hidden) {
        return
      }
      const isSelected: boolean = index === this.selected
      const isNeighbor: boolean = highlighted.includes(index)
      const eraDimmed: boolean = hasEraFilter && !eraSet.has(index)
      const dimmed: boolean = eraDimmed || (hasSelection && !isSelected && !isNeighbor)

      // 淡出用透明度而不是浅色 —— 浅色圆点仍占满画面，看起来就是一团噪声
      // Obsidian 的节点就是小圆点 —— 大圆饼会把画面压死，也失去「点」的语义。
      // 站点节点略大一点点用于区分层级，而不是放大 1.5 倍那种夸张
      const isSiteNode: boolean = node.type === 'Site'
      const baseR: number = (3.2 + node.weight * 5.0) * (isSiteNode ? 1.5 : 1)
      const r: number = Math.max(2.2, baseR * this.viewScale()) * (isSelected ? 1.6 : 1)
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
      // Obsidian 的规则：**默认一个标签都不显示**，只在选中节点及其邻居上出现。
      // 这样全图看的是「形状」，细节靠点击探索 —— 之前把标签全铺开是根本性错误
      const showLabel: boolean = isSelected || isNeighbor
      if (showLabel) {
        const fontSize: number = isSelected ? 14 : 12
        this.ctx.font = `${fontSize}px sans-serif`
        this.ctx.globalAlpha = dimmed ? 0.3 : 1
        // 径向布局：标签按节点相对圆心的方向朝外摆，不会压回中心节点
        let tx: number = nx + r + 4
        if (this.focusSite >= 0 && !isSiteNode) {
          const dx: number = nx - this.ctx.width / 2
          // 左半圆上的节点标签放左侧，右半圆放右侧
          tx = dx < 0 ? nx - r - 4 - node.name.length * fontSize * 0.6 : nx + r + 4
        }
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
            this.applyFocusLayout()
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

      // 遗址切换条：默认聚焦单个遗址（径向自我网络），也可切到全图
      if (this.siteIndices.length > 0) {
        Scroll() {
          Row({ space: 8 }) {
            Text('全图')
              .fontSize(11)
              .fontColor(this.focusSite < 0 ? AppColor.surface : AppColor.textSecondary)
              .backgroundColor(this.focusSite < 0 ? AppColor.primary : AppColor.background)
              .padding({ left: 10, right: 10, top: 6, bottom: 6 })
              .borderRadius(13)
              .onClick(() => {
                this.setFocus(-1)
              })
            ForEach(
              this.siteIndices,
              (idx: number, order: number) => {
                Text(this.layout.nodes[idx].name)
                  .fontSize(11)
                  .fontColor(this.focusSite === order ? AppColor.surface : AppColor.textSecondary)
                  .backgroundColor(
                    this.focusSite === order ? AppColor.primary : AppColor.background
                  )
                  .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                  .borderRadius(13)
                  .onClick(() => {
                    this.setFocus(order)
                  })
              },
              (idx: number) => `site-${idx}`
            )
          }
          .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        .padding({ top: 4, bottom: 4 })
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
