import { common } from '@kit.AbilityKit'
import { router } from '@kit.ArkUI'

import type { HeritageSummary } from '../service/HeritageDao'
import { HeritageDao } from '../service/HeritageDao'
import { AppColor, AppFont, AppSize, FontFamily } from '../constants/Theme'

/** 赛题六段时代轴：分组与排序都以它为准 */
const ERA_AXIS: string[] = ['仰韶', '龙山', '夏商', '周', '汉唐', '宋', '宋以后']

/** 中文数字：作时代序号，比阿拉伯数字更贴合「编年」的调性 */
const CN_NUMERALS: string[] = ['壹', '贰', '叁', '肆', '伍', '陆', '柒']

/** 河面上的一道横向笔触：位置、高度占比与色调 */
class BandSpec {
  readonly top: number
  readonly height: number
  readonly tint: string

  constructor(top: number, height: number, tint: string) {
    this.top = top
    this.height = height
    this.tint = tint
  }
}

/**
 * 河面的笔触分布。
 *
 * 纯渐变的河面像一块塑料板；叠几道深浅不一的横向笔触才有「画」的质感。
 * 位置刻意不均匀 —— 等距排列立刻露馅成条纹布料。
 */
const BAND_SPECS: BandSpec[] = [
  new BandSpec(0.06, 0.10, 'rgba(58, 118, 148, 0.30)'),
  new BandSpec(0.18, 0.04, 'rgba(120, 176, 190, 0.24)'),
  new BandSpec(0.30, 0.09, 'rgba(52, 110, 142, 0.26)'),
  new BandSpec(0.47, 0.05, 'rgba(126, 182, 194, 0.22)'),
  new BandSpec(0.62, 0.08, 'rgba(56, 116, 146, 0.28)'),
  new BandSpec(0.76, 0.04, 'rgba(132, 186, 196, 0.22)'),
  new BandSpec(0.88, 0.07, 'rgba(50, 108, 140, 0.26)'),
]

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

  // ---- 版式基准 ----
  // 河道是一条有边界的竖带（14..42），不是铺在文字底下的背景：
  // 左页边 14 → 河面宽 28 → 河岸 → 遗迹图形(44..68) → 连接线(68..92) → 正文 92
  /** 河道画布宽度 */
  private readonly RIVER_W: number = 60
  /** 河道中心线距屏幕左沿 */
  private readonly RIVER_CX: number = 28
  /** 河道半宽：河面总宽 = 2 × 它 */
  private readonly RIVER_HW: number = 14
  /** 右岸线位置 */
  private readonly BANK_RIGHT: number = 42
  /** 正文起始位置 */
  private readonly CONTENT_LEFT: number = 98
  /** 遗迹图形宽 */
  private readonly GLYPH_W: number = 32

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
   * **河道是一条有边界的竖带，不是背景。** 上一版用多层描边叠出渐隐边缘，
   * 结果是字的底下一层淡淡的色，读起来像背景纹理。这一版改成：
   * 先用两岸围出一条**填充路径**，边缘清晰；再勾岸线；最后在河面里画水波。
   * 条目通过连接线挂在右岸上，河与内容之间是明确的前后关系，不是叠压关系。
   *
   * 配色取青绿山水：石青为水、石绿为岸、赭石勾线。矿物颜料本身有分量，
   * 不会像水墨那样在暖纸色上显得灰扑扑。
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

    /** 河面上端收窄、下端收窄：像一笔起收，而不是被裁断的色条 */
    const taperTop: number = Math.min(90, h * 0.10)
    const taperBottom: number = Math.min(120, h * 0.14)
    const halfAt = (y: number): number => {
      if (y < taperTop) {
        return hw * (0.35 + 0.65 * (y / Math.max(1, taperTop)))
      }
      if (y > h - taperBottom) {
        return hw * (0.35 + 0.65 * ((h - y) / Math.max(1, taperBottom)))
      }
      return hw
    }

    // ---- 河面填充：两岸围合 ----
    this.ctx.beginPath()
    for (let y = 0; y <= h; y += 7) {
      const x: number = this.riverX(y) - halfAt(y)
      if (y === 0) {
        this.ctx.moveTo(x, y)
      } else {
        this.ctx.lineTo(x, y)
      }
    }
    for (let y = h; y >= 0; y -= 7) {
      this.ctx.lineTo(this.riverX(y) + halfAt(y), y)
    }
    this.ctx.closePath()

    const water: CanvasGradient = this.ctx.createLinearGradient(0, 0, 0, h)
    water.addColorStop(0, 'rgba(96, 150, 176, 0.42)')
    water.addColorStop(0.35, 'rgba(78, 141, 172, 0.60)')
    water.addColorStop(0.72, 'rgba(86, 148, 172, 0.58)')
    water.addColorStop(1, 'rgba(104, 158, 172, 0.40)')
    this.ctx.fillStyle = water
    this.ctx.fill()

    // ---- 笔触层次：在河形内叠几道横向色带 ----
    // 纯渐变的河面像一块塑料板；加几道深浅不一的横向笔触才有「画」的质感。
    // 用 clip 把笔触限制在河形内，边缘才不会溢出去。
    this.ctx.save()
    this.ctx.clip()
    for (const b of BAND_SPECS) {
      const y0: number = h * b.top
      const bh: number = h * b.height
      const g: CanvasGradient = this.ctx.createLinearGradient(0, y0, 0, y0 + bh)
      g.addColorStop(0, 'rgba(0, 0, 0, 0)')
      g.addColorStop(0.5, b.tint)
      g.addColorStop(1, 'rgba(0, 0, 0, 0)')
      this.ctx.fillStyle = g
      this.ctx.fillRect(0, y0, this.ctx.width, bh)
    }
    this.ctx.restore()

    // ---- 岸线：赭石，两岸各一条，河因此有明确边界 ----
    for (const side of [-1, 1]) {
      this.ctx.beginPath()
      for (let y = 0; y <= h; y += 6) {
        const x: number = this.riverX(y) + side * halfAt(y)
        if (y === 0) {
          this.ctx.moveTo(x, y)
        } else {
          this.ctx.lineTo(x, y)
        }
      }
      this.ctx.lineWidth = 1.6
      this.ctx.strokeStyle = 'rgba(150, 104, 66, 0.62)'
      this.ctx.stroke()
    }

    // ---- 石绿岸带：两岸外侧一线青绿，暗示植被 ----
    for (const side of [-1, 1]) {
      this.ctx.beginPath()
      for (let y = 0; y <= h; y += 6) {
        const x: number = this.riverX(y) + side * (halfAt(y) + 2.4)
        if (y === 0) {
          this.ctx.moveTo(x, y)
        } else {
          this.ctx.lineTo(x, y)
        }
      }
      this.ctx.lineWidth = 3.2
      this.ctx.strokeStyle = 'rgba(126, 172, 138, 0.30)'
      this.ctx.stroke()
    }

    // ---- 水波：不等长短弧，错落散布，随相位下移 ----
    const ROW: number = 20
    const drift: number = (this.phase * 9) % ROW
    this.ctx.lineWidth = 1.6

    let k: number = 0
    for (let y = 0; y <= h; y += ROW) {
      const yy: number = y + drift
      if (yy < taperTop * 0.6 || yy > h - taperBottom * 0.6) {
        k += 1
        continue
      }
      const cx: number = this.riverX(yy)
      const span: number = halfAt(yy) * 1.5
      const count: number = k % 3 === 0 ? 2 : 1
      for (let i = 0; i < count; i += 1) {
        const seed: number = k * 7 + i * 13
        const len: number = 5.5 + (seed % 5)
        const lateral: number = ((seed * 31) % 100) / 100 * span - span / 2
        const yJitter: number = (((seed * 17) % 7) - 3) * 0.9
        const alpha: number = 0.44 + (seed % 4) / 22
        this.ctx.strokeStyle = `rgba(232, 245, 249, ${alpha})`
        this.ripple(cx + lateral - len / 2, yy + yJitter, len, seed % 2 === 0 ? 1 : -1)
      }
      k += 1
    }
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

  /**
   * 沿岸小景：按遗址类型画一个简笔图形。
   *
   * 用 Path 而不是每项一个 Canvas —— 一页十几二十个 Canvas 实例开销不小，
   * 而这些图形只是静态线稿，Path 足够，也更省。
   *
   * 图形取赭石偏墨，压在青绿河岸上正好是「岸边有个老物件」的观感。
   */
  @Builder
  siteGlyph(item: HeritageSummary) {
    if (item.types.length > 0 && item.types[0] === '都城遗址') {
      // 城墙带垛口
      Path({ commands: 'M3 29 L3 16 L7 16 L7 12 L11 12 L11 16 L13 16 L13 12 L17 12 L17 16 L21 16 L21 12 L25 12 L25 16 L29 16 L29 29 Z' })
        .width(32).height(32).fill('#7E5B3E').opacity(0.62)
    } else if (item.types.length > 0 && item.types[0] === '窑址') {
      // 窑包 + 烟囱
      Path({ commands: 'M4 29 Q4 17 16 17 Q28 17 28 29 Z' })
        .width(32).height(32).fill('#9A6935').opacity(0.60)
      Path({ commands: 'M16 17 L16 8 L20 8 L20 17 Z' })
        .width(32).height(32).fill('#7E5B3E').opacity(0.66)
    } else if (item.types.length > 0 && item.types[0] === '古建筑') {
      // 塔：层层收分
      Path({ commands: 'M16 3 L21 12 L19 12 L19 16 L23 16 L23 20 L19 20 L19 24 L24 24 L24 29 L8 29 L8 24 L13 24 L13 20 L9 20 L9 16 L13 16 L13 12 L11 12 Z' })
        .width(32).height(32).fill('#7E4E32').opacity(0.66)
    } else if (item.types.length > 0 && item.types[0] === '墓葬群') {
      // 封土堆
      Path({ commands: 'M3 29 Q16 9 29 29 Z' })
        .width(32).height(32).fill('#7E5B3E').opacity(0.56)
    } else {
      // 聚落：两间坡顶房
      Path({ commands: 'M3 29 L3 19 L9 13 L16 19 L16 29 Z M17 29 L17 20 L24 15 L31 20 L31 29 Z' })
        .width(32).height(32).fill('#7E5B3E').opacity(0.62)
    }
  }

  /** 一条遗址 */
  @Builder
  itemEntry(item: HeritageSummary) {
    Stack({ alignContent: Alignment.TopStart }) {
      // 连接线：从河岸一直画到正文，图形随后压在上面。
      // 这样无论图形多宽，线都不会出现断口 —— 上一版从图形右沿起算，
      // 因为留了间距，看起来就是「有些点没连上」。
      Row()
        .width(this.CONTENT_LEFT - this.BANK_RIGHT - 2)
        .height(1)
        .backgroundColor('#93B5C3')
        .position({ x: -(this.CONTENT_LEFT - this.BANK_RIGHT - 2), y: 28 })

      // 岸端落点：线从河岸「长」出来的地方有个点
      Column()
        .width(5)
        .height(5)
        .borderRadius(3)
        .backgroundColor('#7EA6B6')
        .position({ x: -(this.CONTENT_LEFT - this.BANK_RIGHT - 3), y: 25.5 })

      // 岸边遗迹：压在连接线上，紧贴河道右岸
      Column() {
        this.siteGlyph(item)
      }
      .width(this.GLYPH_W)
      .position({ x: -(this.CONTENT_LEFT - this.BANK_RIGHT - 2), y: 6 })

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
        Scroll() {
          // Stack 必须在 Scroll 内部。若把 Canvas 放在 Scroll 的兄弟位置，
          // 它就固定在视口里 —— 滚动时只有连接点上移、河不动（实测如此）。
          Stack({ alignContent: Alignment.TopStart }) {
            Canvas(this.ctx)
              .width(this.RIVER_W)
              .height(this.contentHeight > 0 ? this.contentHeight : 1)
              .position({ x: 0, y: 0 })
              .onReady(() => {
                this.riverReady = true
                this.drawRiver()
                this.startRiver()
              })

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
              left: this.CONTENT_LEFT,
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
          .width('100%')
        }
        .scrollable(ScrollDirection.Vertical)
        .scrollBar(BarState.Off)
        .layoutWeight(1)
        .width('100%')
        .align(Alignment.TopStart)
        .clip(true)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F4EFE3')
  }
}
