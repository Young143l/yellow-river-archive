import { common } from '@kit.AbilityKit'
import { router } from '@kit.ArkUI'

import type { HeritageSummary } from '../service/HeritageDao'
import { HeritageDao } from '../service/HeritageDao'
import { AppColor, AppFont, AppSize, FontFamily } from '../constants/Theme'

/** 赛题六段时代轴：分组与排序都以它为准 */
const ERA_AXIS: string[] = ['仰韶', '龙山', '夏商', '周', '汉唐', '宋', '宋以后']

/** 中文数字：作时代序号，比阿拉伯数字更贴合「编年」的调性 */
const CN_NUMERALS: string[] = ['壹', '贰', '叁', '肆', '伍', '陆', '柒']

/** 一个时代分组 */
class EraGroup {
  readonly era: string
  readonly items: HeritageSummary[]
  readonly index: number

  constructor(era: string, items: HeritageSummary[], index: number) {
    this.era = era
    this.items = items
    this.index = index
  }
}

/**
 * 首页：竖排河卷。
 *
 * 视觉上不用任何插画，全靠排版 —— 这不是偷懒，是必须：
 * rawfile 里的五张「照片」实测是纯色渐变占位图，任何依赖图像的版式都撑不起来。
 * 于是把力气放在能控制的地方：宋体、留白、细线、朱砂色、印章、中文序号。
 */
@Component
export struct HomePage {
  @State loading: boolean = true
  @State error: string = ''
  @State groups: EraGroup[] = []
  @State total: number = 0

  /** 河道画布宽度 */
  private readonly RIVER_W: number = 74
  /** 河道中心线距屏幕左沿的距离 */
  private readonly RIVER_CX: number = 32
  /** 河道半宽：河面总宽 = 2 × 它 */
  private readonly RIVER_HW: number = 9
  /** 河道中心线到正文的距离 */
  private readonly RIVER_GAP: number = 26

  private settings: RenderingContextSettings = new RenderingContextSettings(true)
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings)
  private riverReady: boolean = false
  private timer: number = -1
  /** 动画相位：驱动波形漂移与水流推进 */
  private phase: number = 0
  /**
   * 内容总高度（vp）。河道画布要按它定高，才能随内容一起滚动。
   *
   * 为什么必须等布局后才知道：Canvas 若写死 height('100%')，
   * 在 Scroll 里会被解析成视口高度，滚动时河道就与内容脱节了。
   * 所以由内容列用 onAreaChange 量出真实高度，再回填给画布。
   */
  @State contentHeight: number = 0
  private viewportHeight: number = 0

  aboutToAppear(): void {
    this.load()
  }

  aboutToDisappear(): void {
    if (this.timer !== -1) {
      clearInterval(this.timer)
      this.timer = -1
    }
  }

  private async load(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.Context
      await HeritageDao.ready(context)
      const all: HeritageSummary[] = HeritageDao.list()
      this.total = all.length
      this.groups = HomePage.groupByEra(all)
      this.loading = false
    } catch (err) {
      this.error = `档案加载失败：${err}`
      this.loading = false
    }
  }

  /**
   * 按赛题时代轴分组，组内按经度自西向东。
   *
   * 组内按经度而不是名称：五处遗址沿黄河自西向东排列，
   * 按经度排能让每个时代内部也保持「从上游到下游」的地理顺序。
   */
  private static groupByEra(all: HeritageSummary[]): EraGroup[] {
    const out: EraGroup[] = []
    let seq: number = 0
    for (const era of ERA_AXIS) {
      const bucket: HeritageSummary[] = all.filter((item: HeritageSummary) => item.era === era)
      if (bucket.length === 0) {
        // 空时代不显示 —— 首页是内容入口，不是覆盖率报表
        continue
      }
      bucket.sort((a: HeritageSummary, b: HeritageSummary) => a.lng - b.lng)
      out.push(new EraGroup(era, bucket, seq))
      seq += 1
    }
    return out
  }

  private openDetail(id: string): void {
    router.pushUrl({ url: 'pages/DetailPage', params: { id } })
  }

  // ---------------------------------------------------------------- 河道

  /**
   * 河道中心线：两道正弦叠加。
   *
   * 单道正弦的波形太"机械"，一看就是画出来的；叠一道频率 2.7 倍、
   * 相位不同步的弱波之后，摆动变得不规则，才像自然河道。
   */
  private riverX(y: number): number {
    const cx: number = this.RIVER_CX
    // 振幅收在 ±7 以内，保证河面不会压到右侧文字
    const a: number = Math.sin(y * 0.0068) * 7.0
    const b: number = Math.sin(y * 0.0176) * 2.4
    return cx + a + b
  }

  private traceRiver(h: number, dx: number): void {
    this.ctx.beginPath()
    for (let y = -12; y <= h + 12; y += 9) {
      const x: number = this.riverX(y) + dx
      if (y === -12) {
        this.ctx.moveTo(x, y)
      } else {
        this.ctx.lineTo(x, y)
      }
    }
  }

  /**
   * 绘制河道（青绿山水）。
   *
   * 定调：**彩色国画**，不是水墨。青绿山水用矿物颜料，石青画水、
   * 石绿画岸、赭石勾线 —— 这套配色本身就有分量，不会像水墨那样在
   * 暖纸色上显得灰扑扑。
   *
   * 结构（由外到内）：
   *   石绿岸带（两岸植被） → 石青河面 → 亮青河心 → 赭石岸线 → 白青水波
   *
   * 河道画布高度 = 内容总高，因此它随内容一起滚动，就是一条时间轴。
   */
  private drawRiver(): void {
    const w: number = this.ctx.width
    const h: number = this.ctx.height
    if (w <= 0 || h <= 0) {
      return
    }
    this.ctx.clearRect(0, 0, w, h)
    this.ctx.lineCap = 'round'
    this.ctx.lineJoin = 'round'

    const hw: number = this.RIVER_HW
    const clip: number = Math.max(1, h)
    const fade: number = Math.min(85, h * 0.10)

    /** 纵向渐隐：卷首起笔、卷末收笔，两端淡出 */
    const grad = (r: number, g: number, b: number, alpha: number): CanvasGradient => {
      const c: CanvasGradient = this.ctx.createLinearGradient(0, 0, 0, h)
      c.addColorStop(0, `rgba(${r}, ${g}, ${b}, 0)`)
      c.addColorStop(Math.min(0.4, fade / clip), `rgba(${r}, ${g}, ${b}, ${alpha})`)
      c.addColorStop(Math.max(0.6, 1 - fade / clip), `rgba(${r}, ${g}, ${b}, ${alpha})`)
      c.addColorStop(1, `rgba(${r}, ${g}, ${b}, 0)`)
      return c
    }

    // ---- 1. 石绿岸带：河两侧的植被，给河道一圈绿意 ----
    this.traceRiver(h, 0)
    this.ctx.lineWidth = hw * 2.75
    this.ctx.strokeStyle = grad(126, 172, 138, 0.26)
    this.ctx.stroke()

    // ---- 2. 石青河面 ----
    this.traceRiver(h, 0)
    this.ctx.lineWidth = hw * 2.0
    this.ctx.strokeStyle = grad(78, 140, 172, 0.44)
    this.ctx.stroke()

    // ---- 3. 河心亮青：只加一点点，且不做成一条贯通亮线 ----
    // 上一版在中轴画了一道亮条，整条河看起来像塑料管。
    // 改成两段错开的短带，只做局部的明暗起伏。
    for (const seg of [[0.12, 0.34], [0.48, 0.72], [0.80, 0.94]]) {
      this.ctx.beginPath()
      let started: boolean = false
      for (let y = h * seg[0]; y <= h * seg[1]; y += 6) {
        const x: number = this.riverX(y) - hw * 0.26
        if (!started) {
          this.ctx.moveTo(x, y)
          started = true
        } else {
          this.ctx.lineTo(x, y)
        }
      }
      this.ctx.lineWidth = hw * 0.55
      this.ctx.strokeStyle = grad(168, 213, 228, 0.18)
      this.ctx.stroke()
    }

    // ---- 4. 赭石岸线：矿物土色勾边，比墨线暖，也更像工笔的轮廓 ----
    for (const side of [-1, 1]) {
      this.ctx.beginPath()
      for (let y = -10; y <= h + 10; y += 6) {
        const x: number = this.riverX(y) + side * hw
        if (y === -10) {
          this.ctx.moveTo(x, y)
        } else {
          this.ctx.lineTo(x, y)
        }
      }
      this.ctx.lineWidth = 1.1
      this.ctx.strokeStyle = grad(154, 107, 68, 0.58)
      this.ctx.stroke()
    }

    // ---- 5. 水波：不等长的短弧，错落散布 ----
    // 上一版把左右两笔配成对、长度接近，结果每行连成一条横贯的线，
    // 整条河看着像铁轨或梯子。水波要「散」：长度、横向位置、纵向位置都错开。
    const ROW: number = 17
    const drift: number = (this.phase * 9) % ROW
    this.ctx.lineWidth = 1.5

    let k: number = 0
    for (let y = -ROW; y <= h + ROW; y += ROW) {
      const cx: number = this.riverX(y + drift)
      // 每行放 1-2 笔，位置按行号伪随机分布
      const count: number = k % 3 === 0 ? 2 : 1
      for (let i = 0; i < count; i += 1) {
        const seed: number = k * 7 + i * 13
        const len: number = 5.5 + (seed % 5)
        const lateral: number = ((seed * 31) % 100) / 100 * (hw * 1.5) - hw * 0.75
        const yJitter: number = (((seed * 17) % 7) - 3) * 0.9
        const alpha: number = 0.5 + (seed % 4) / 20
        this.ctx.strokeStyle = grad(228, 243, 248, alpha)
        this.ripple(cx + lateral - len / 2, y + drift + yJitter, len, seed % 2 === 0 ? 1 : -1)
      }
      k += 1
    }

    // ---- 6. 一点暖色高光，模拟矿物颜料的颗粒反光 ----
    this.ctx.lineWidth = 0.9
    this.ctx.strokeStyle = grad(246, 232, 200, 0.30)
    this.traceRiver(h, -hw * 0.30)
    this.ctx.stroke()
  }

  /** 一道水波：短横弧；dir 取 ±1 让相邻笔起伏反向，才像水 */
  private ripple(x: number, y: number, len: number, dir: number): void {
    this.ctx.beginPath()
    this.ctx.moveTo(x, y)
    this.ctx.quadraticCurveTo(x + len / 2, y + 1.9 * dir, x + len, y)
    this.ctx.stroke()
  }

  private startRiver(): void {
    if (!this.riverReady || this.timer !== -1) {
      return
    }
    if (this.contentHeight > 9000) {
      // 内容极长时（80 条档案）整条河每帧重绘会拖慢滚动，
      // 退化为静态河道 —— 有动效是加分，掉帧是减分
      this.drawRiver()
      return
    }
    // 30fps 足够表达水流；60fps 只是白烧电
    this.timer = setInterval(() => {
      this.phase += 0.022
      this.drawRiver()
    }, 33)
  }

  // ---------------------------------------------------------------- 部件

  /** 印章：朱底白字，微旋。中式版式里最省力的「郑重」信号 */
  @Builder
  seal() {
    Column() {
      Text('河')
        .fontSize(15)
        .fontFamily(FontFamily.serifBold)
        .fontColor('#FBF7F0')
      Text('图')
        .fontSize(15)
        .fontFamily(FontFamily.serifBold)
        .fontColor('#FBF7F0')
    }
    .width(34)
    .height(46)
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#A2392B')
    .borderRadius(3)
    .rotate({ angle: 3 })
  }

  /** 卷首 */
  @Builder
  masthead() {
    Column({ space: 0 }) {
      Row() {
        Column({ space: 10 }) {
          Text('黄河图志')
            .fontSize(33)
            .fontFamily(FontFamily.serifBold)
            .fontColor('#2A2520')
            .letterSpacing(5)
          Row()
            .width(38)
            .height(2)
            .backgroundColor('#A2392B')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        this.seal()
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      Text('河南段黄河文化遗产')
        .fontSize(12)
        .fontColor('#8B7F71')
        .letterSpacing(2)
        .margin({ top: 18 })

      Text(`${this.total} 处遗址 · ${this.groups.length} 个时代 · 自西向东`)
        .fontSize(11)
        .fontColor('#A99D8E')
        .letterSpacing(1)
        .margin({ top: 5 })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  /** 时代标题：巨大浅色中文字号作底，朱砂标题压在上面 */
  @Builder
  eraHeader(group: EraGroup) {
    Row({ space: 12 }) {

      // 序号：大、淡、衬线，像书页边上的编次
      Text(CN_NUMERALS[group.index % CN_NUMERALS.length])
        .fontSize(44)
        .fontFamily(FontFamily.serif)
        .fontColor('#E3D9C9')

      Column({ space: 3 }) {
        Text(group.era)
          .fontSize(25)
          .fontFamily(FontFamily.serifBold)
          .fontColor('#8E3423')
          .letterSpacing(3)
        Text(`${group.items.length} 处`)
          .fontSize(10)
          .fontColor('#A99D8E')
          .letterSpacing(1)
      }
      .alignItems(HorizontalAlign.Start)
    }
    .alignItems(VerticalAlign.Bottom)
    .width('100%')
  }

  /** 一条遗址 */
  @Builder
  itemEntry(item: HeritageSummary) {
    Column({ space: 7 }) {
      Text(item.name)
        .fontSize(20)
        .fontFamily(FontFamily.serif)
        .fontColor('#2A2520')
        .letterSpacing(1)
        .width('100%')

      Row({ space: 7 }) {
        Text(item.city)
          .fontSize(11)
          .fontColor('#8E3423')
        Text('/')
          .fontSize(11)
          .fontColor('#CFC4B4')
        Text(item.types.length > 0 ? item.types[0] : '')
          .fontSize(11)
          .fontColor('#7C7266')
        if (item.level.length > 0) {
          Text('/')
            .fontSize(11)
            .fontColor('#CFC4B4')
          Text(item.level)
            .fontSize(11)
            .fontColor('#7C7266')
        }
      }
      .width('100%')

      Text(item.summary)
        .fontSize(13)
        .fontColor('#5C5348')
        .lineHeight(24)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .letterSpacing(0.3)
        .width('100%')
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding({ top: 16, bottom: 18 })
    .onClick(() => {
      this.openDetail(item.id)
    })
  }

  /** 条目之间的分隔：单细线，右端渐隐，比通栏实线轻 */
  @Builder
  hairline() {
    Row()
      .width('100%')
      .height(1)
      .linearGradient({
        angle: 90,
        colors: [['#E2D9CA', 0.0], ['#EFE8DC', 0.85], ['#F4EFE3', 1.0]],
      })
  }

  /** 卷末：一条短横线加一点，收住整页 */
  @Builder
  colophon() {
    Column({ space: 10 }) {
      Row()
        .width(28)
        .height(1)
        .backgroundColor('#D6CCBB')
      Text('卷 终')
        .fontSize(10)
        .fontColor('#B3A797')
        .letterSpacing(4)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .padding({ top: 44, bottom: 30 })
  }

  // ---------------------------------------------------------------- 视图

  build() {
    Column() {
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
        Stack({ alignContent: Alignment.TopStart }) {
          // 河道画布：高度 = 内容总高，放在 Scroll 之前作为底层，
          // 因此它会跟着内容一起滚动 —— 河道是内容骨架，不是背景装饰。
          Canvas(this.ctx)
            .width(this.RIVER_W)
            .height(this.contentHeight > 0 ? this.contentHeight : '100%')
            .position({ x: 0, y: 0 })
            .onReady(() => {
              this.riverReady = true
              this.drawRiver()
              this.startRiver()
            })

          Scroll() {
            Column() {
              this.masthead()
              ForEach(
              this.groups,
              (group: EraGroup) => {
                Column() {
                  this.eraHeader(group)
                  ForEach(
                    group.items,
                    (item: HeritageSummary, idx: number) => {
                      Column() {
                        this.itemEntry(item)
                        if (idx < group.items.length - 1) {
                          this.hairline()
                        }
                      }
                      .width('100%')
                    },
                    (item: HeritageSummary) => item.id
                  )
                }
                .width('100%')
                .alignItems(HorizontalAlign.Start)
                .padding({ top: 30 })
              },
              (group: EraGroup) => group.era
            )
              this.colophon()
            }
            .padding({
              left: this.RIVER_CX + this.RIVER_GAP + 4,
              right: AppSize.pagePadding + 4,
              top: 26,
              bottom: 8,
            })
          .width('100%')
          .onAreaChange((_old: Area, now: Area) => {
            const h: number = Number(now.height)
            if (h > 0 && Math.abs(h - this.contentHeight) > 1) {
              this.contentHeight = h
              this.drawRiver()
            }
          })
          }
          .scrollable(ScrollDirection.Vertical)
          .scrollBar(BarState.Off)
          .width('100%')
          .height('100%')
          .align(Alignment.TopStart)
        }
        .layoutWeight(1)
        .width('100%')
        .clip(true)
        .onAreaChange((_old: Area, now: Area) => {
          const h: number = Number(now.height)
          if (h > 0) {
            this.viewportHeight = h
          }
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F4EFE3')
  }
}
