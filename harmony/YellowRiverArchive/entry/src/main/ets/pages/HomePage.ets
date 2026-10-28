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
  new BandSpec(0.05, 0.11, 'rgba(34, 82, 108, 0.26)'),
  new BandSpec(0.19, 0.05, 'rgba(150, 202, 216, 0.24)'),
  new BandSpec(0.31, 0.09, 'rgba(30, 78, 104, 0.24)'),
  new BandSpec(0.46, 0.06, 'rgba(156, 208, 220, 0.22)'),
  new BandSpec(0.60, 0.09, 'rgba(32, 80, 106, 0.26)'),
  new BandSpec(0.74, 0.05, 'rgba(152, 204, 218, 0.22)'),
  new BandSpec(0.87, 0.08, 'rgba(28, 74, 100, 0.24)'),
]

/**
 * 河心沙洲：[纵向位置占比, 宽度系数, 横向偏移(-1..1), 纵向半径系数]
 *
 * 黄河下游是著名的宽浅游荡型河道，沙洲与汊道是它的标志性地貌。
 * 画几处浅色滩地，河就不再是一条均匀的带子。
 */
/** 汊道：offset 为相对河宽的横向偏移，freq/phase 决定摆动，width 为线宽 */
class BraidSpec {
  readonly offset: number
  readonly freq: number
  readonly phase: number
  readonly width: number
  readonly tint: string

  constructor(offset: number, freq: number, phase: number, width: number, tint: string) {
    this.offset = offset
    this.freq = freq
    this.phase = phase
    this.width = width
    this.tint = tint
  }
}

/**
 * 次级水流。
 *
 * 黄河下游是宽浅游荡型河道：主槽之外还有多条汊道，之间夹着心滩。
 * 只画一条均匀的水带，无论配色多准都不像黄河；有汊道才有那种"散"的形态。
 */
const BRAIDS: BraidSpec[] = [
  new BraidSpec(-0.46, 0.0061, 0.4, 9, 'rgba(204, 170, 104, 0.55)'),
  new BraidSpec(0.40, 0.0049, 2.1, 7, 'rgba(196, 160, 96, 0.50)'),
  new BraidSpec(-0.02, 0.0077, 1.2, 5, 'rgba(212, 180, 116, 0.40)'),
]

const SANDBARS: number[][] = [
  [0.16, 0.55, -0.30, 1.5],
  [0.34, 0.42, 0.34, 1.1],
  [0.55, 0.60, -0.22, 1.8],
  [0.72, 0.38, 0.40, 1.0],
  [0.86, 0.48, -0.34, 1.4],
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
  // 河宽比例是这一版的关键决定。45px 在 360px 屏上只占 12.5%，
  // 只够画一条"带子"——沙洲、汊道、宽窄变化都表现不出来，所以显得窄。
  // 加到 100px（约 28%）之后，河才有了"面"，能画宽浅游荡型河道的地貌。
  // 代价是正文从 240px 收窄到 218px，仍容得下约 17 个汉字/行。
  /** 河道画布宽度 */
  private readonly RIVER_W: number = 106
  /** 河道中心线距屏幕左沿 */
  private readonly RIVER_CX: number = 55
  /** 河道半宽基准：实际宽度会在此基础上随流程起伏 */
  private readonly RIVER_HW: number = 35
  /** 右岸线位置 */
  private readonly BANK_RIGHT: number = 97
  /** 遗迹图形左沿（压在右岸上，不额外占用正文宽度） */
  private readonly GLYPH_LEFT: number = 76
  /** 正文起始位置 */
  private readonly CONTENT_LEFT: number = 112
  /** 遗迹图形宽 */
  private readonly GLYPH_W: number = 30

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
  /**
   * 河道中心线：三道正弦叠加。
   *
   * 单一长波正弦画出来是「一条蛇」—— 起伏太规则、波长太长。
   * 叠上频率 3 倍与 7 倍的弱波之后，弯道变得长短不一，
   * 接近真实河道那种「一段缓弯接一个小折」的走向。
   */
  private riverX(y: number): number {
    const cx: number = this.RIVER_CX
    return cx +
      Math.sin(y * 0.0045 + 1.1) * 8.5 +
      Math.sin(y * 0.0132 + 0.4) * 4.2 +
      Math.sin(y * 0.0310 + 2.2) * 1.8
  }

  /**
   * 河道半宽：随流程变宽变窄。
   *
   * 等宽的河道是蛇，不是河。真实河流在峡谷处收窄、在滩地散开，
   * 黄河下游更是著名的宽浅游荡型河道。宽度变化是「河」最有效的信号之一。
   */
  private riverHalf(y: number, h: number): number {
    // 不再在两端收尖。
    //
    // 之前两端收窄到 0.3、中段鼓到 1.1，形状就是一条鱼 —— 宽身子加尖头尖尾。
    // 河不是物件，它应该从画面外流进来、再流出画面；两端收尖恰好把河
    // 变成了一个封闭的图形。现在改为宽度基本恒定、只在首尾用透明度淡出，
    // 观感是"河流出画"而不是"一条鱼"。
    //
    // 起伏也压平：真实河流在图上宽度相当稳定，靠弯曲与汊道提供形态，
    // 不靠宽度鼓包。
    const vary: number =
      0.94 +
      0.05 * Math.sin(y * 0.0052 + 2.0) +
      0.04 * Math.sin(y * 0.0137 + 0.9)
    return this.RIVER_HW * Math.max(0.84, Math.min(1.04, vary))
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
  /** 在河道里填充一条水道：centerOff/halfRatio 都随流程变化，水道才会时分时合 */
  private fillChannel(
    h: number,
    centerOff: (y: number) => number,
    halfRatio: (y: number) => number,
    tint: string
  ): void {
    this.ctx.beginPath()
    for (let y = 0; y <= h; y += 5) {
      const hw: number = this.riverHalf(y, h)
      const x: number = this.riverX(y) + centerOff(y) * hw - halfRatio(y) * hw
      if (y === 0) {
        this.ctx.moveTo(x, y)
      } else {
        this.ctx.lineTo(x, y)
      }
    }
    for (let y = h; y >= 0; y -= 5) {
      const hw: number = this.riverHalf(y, h)
      this.ctx.lineTo(this.riverX(y) + centerOff(y) * hw + halfRatio(y) * hw, y)
    }
    this.ctx.closePath()
    this.ctx.fillStyle = tint
    this.ctx.fill()
  }

  /**
   * 绘制河道（宽浅游荡型）。
   *
   * 关键改动：**不再是"一整条填满的水"**。
   * 之前把整个河带填成赭色，放大看就是一块扁平的黄色，汊道与心滩全被压住；
   * 沙洲只能靠叠椭圆硬凑，结果成了一个个圆斑。
   *
   * 现在按真实黄河的地貌来组织：
   *   1. 铺一层河漫滩（浅沙色）
   *   2. 在滩地上开 3 条水道，各自的横向位置与宽度都随流程变化
   *      —— 水道时宽时窄、时分时合，它们之间的空地自然就成了心滩沙洲
   *   3. 水纹只画在水道里，滩地保持干燥
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

    // ---- 1. 河漫滩：整条河带的底，浅沙色 ----
    this.ctx.beginPath()
    for (let y = 0; y <= h; y += 5) {
      const x: number = this.riverX(y) - this.riverHalf(y, h)
      if (y === 0) {
        this.ctx.moveTo(x, y)
      } else {
        this.ctx.lineTo(x, y)
      }
    }
    for (let y = h; y >= 0; y -= 5) {
      this.ctx.lineTo(this.riverX(y) + this.riverHalf(y, h), y)
    }
    this.ctx.closePath()
    // 滩地用赭石黄 —— 黄河的「黄」来自泥沙，落在滩地上，不是水体本身。
    const flood: CanvasGradient = this.ctx.createLinearGradient(0, 0, 0, h)
    flood.addColorStop(0, 'rgba(223, 203, 160, 0.88)')
    flood.addColorStop(0.5, 'rgba(214, 192, 148, 0.92)')
    flood.addColorStop(1, 'rgba(225, 206, 165, 0.86)')
    this.ctx.fillStyle = flood
    this.ctx.fill()

    // ---- 2. 三条水道 ----
    // 每条道的位置与宽度都是 y 的函数：错开的相位让它们时而并行、时交汇
    this.fillChannel(
      h,
      (y: number) => -0.40 + Math.sin(y * 0.0042 + 0.8) * 0.14,
      (y: number) => 0.33 + Math.sin(y * 0.0068 + 2.0) * 0.07,
      'rgba(70, 126, 150, 0.92)'
    )
    this.fillChannel(
      h,
      (y: number) => 0.34 + Math.sin(y * 0.0051 + 2.6) * 0.13,
      (y: number) => 0.25 + Math.sin(y * 0.0079 + 0.4) * 0.06,
      'rgba(84, 142, 164, 0.88)'
    )
    this.fillChannel(
      h,
      (y: number) => -0.02 + Math.sin(y * 0.0033 + 3.4) * 0.22,
      (y: number) => 0.09 + Math.sin(y * 0.0092 + 1.6) * 0.05,
      'rgba(58, 112, 136, 0.90)'
    )

    // ---- 3. 河内细节（裁剪在河带内）----
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

    // ---- 4. 岸线：河带外沿 ----
    for (const side of [-1, 1]) {
      this.ctx.beginPath()
      for (let y = 0; y <= h; y += 5) {
        const x: number = this.riverX(y) + side * this.riverHalf(y, h)
        if (y === 0) {
          this.ctx.moveTo(x, y)
        } else {
          this.ctx.lineTo(x, y)
        }
      }
      this.ctx.lineWidth = 1.7
      this.ctx.strokeStyle = 'rgba(132, 92, 48, 0.72)'
      this.ctx.stroke()
    }

    // ---- 5. 滩地植被：岸外一线青绿 ----
    for (const side of [-1, 1]) {
      this.ctx.beginPath()
      for (let y = 0; y <= h; y += 5) {
        const x: number = this.riverX(y) + side * (this.riverHalf(y, h) + 2.2)
        if (y === 0) {
          this.ctx.moveTo(x, y)
        } else {
          this.ctx.lineTo(x, y)
        }
      }
      this.ctx.lineWidth = 3.4
      this.ctx.strokeStyle = 'rgba(104, 146, 104, 0.30)'
      this.ctx.stroke()
    }

    // ---- 6. 水波：只落在水道范围内 ----
    // 行距不再固定：固定行距会让水波排成横平竖直的网格，看着像缝线。
    // 让每行的间距在 13-27 之间浮动，水波才「散」。
    const drift: number = (this.phase * 9) % 18
    this.ctx.lineWidth = 1.4

    let k: number = 0
    let y: number = -6
    while (y <= h) {
      const yy: number = y + drift
      const hw: number = this.riverHalf(yy, h)
      if (hw < 4) {
        k += 1
        y += 13 + ((k * 37) % 15)
        continue
      }
      const cx: number = this.riverX(yy)
      for (let i = 0; i < 3; i += 1) {
        const seed: number = k * 11 + i * 17
        // 落点对齐到三条水道的中心附近，水波才不会画到滩地上
        const laneOff: number = i === 0 ? -0.40 : (i === 1 ? 0.34 : -0.02)
        const jitter: number = (((seed * 29) % 100) / 100 - 0.5) * 0.22
        const len: number = 6 + (seed % 5)
        const x: number = cx + (laneOff + jitter) * hw
        const yJ: number = yy + (((seed * 13) % 7) - 3) * 0.8
        const alpha: number = 0.38 + (seed % 4) / 26
        this.ctx.strokeStyle = `rgba(224, 242, 248, ${alpha})`
        this.ripple(x - len / 2, yJ, len, seed % 2 === 0 ? 1 : -1)
      }
      k += 1
      y += 13 + ((k * 37) % 15)
    }

    // ---- 7. 首尾淡出：用纸色渐变把两端抹开 ----
    // 河不从收尖结束，而是"流出画面"。这两段遮罩盖住上下各约 56px。
    const fadeH: number = Math.min(56, h * 0.06)
    const top: CanvasGradient = this.ctx.createLinearGradient(0, 0, 0, fadeH)
    top.addColorStop(0, 'rgba(244, 239, 227, 1)')
    top.addColorStop(1, 'rgba(244, 239, 227, 0)')
    this.ctx.fillStyle = top
    this.ctx.fillRect(0, 0, w, fadeH)

    const bottom: CanvasGradient = this.ctx.createLinearGradient(0, h - fadeH, 0, h)
    bottom.addColorStop(0, 'rgba(244, 239, 227, 0)')
    bottom.addColorStop(1, 'rgba(244, 239, 227, 1)')
    this.ctx.fillStyle = bottom
    this.ctx.fillRect(0, h - fadeH, w, fadeH)
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
        .fontColor(AppColor.surface)
      Text('图')
        .fontSize(15)
        .fontFamily(FontFamily.serifBold)
        .fontColor(AppColor.surface)
    }
    .width(34)
    .height(46)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(AppColor.seal)
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
            .fontColor(AppColor.textPrimary)
            .letterSpacing(5)
          Row()
            .width(38)
            .height(2)
            .backgroundColor(AppColor.seal)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        this.seal()
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      Text('河南段黄河文化遗产')
        .fontSize(12)
        .fontColor(AppColor.textTertiary)
        .letterSpacing(2)
        .margin({ top: 18 })

      Text(`${this.total} 处遗址 · ${this.groups.length} 个时代 · 自西向东`)
        .fontSize(11)
        .fontColor(AppColor.textTertiary)
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
        .fontColor(AppColor.divider)

      Column({ space: 3 }) {
        Text(group.era)
          .fontSize(25)
          .fontFamily(FontFamily.serifBold)
          .fontColor(AppColor.seal)
          .letterSpacing(3)
        Text(`${group.items.length} 处`)
          .fontSize(10)
          .fontColor(AppColor.textTertiary)
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
        .width(32).height(32).fill(AppColor.earth).opacity(0.62)
    } else if (item.types.length > 0 && item.types[0] === '窑址') {
      // 窑包 + 烟囱
      Path({ commands: 'M4 29 Q4 17 16 17 Q28 17 28 29 Z' })
        .width(32).height(32).fill(AppColor.earth).opacity(0.60)
      Path({ commands: 'M16 17 L16 8 L20 8 L20 17 Z' })
        .width(32).height(32).fill(AppColor.earth).opacity(0.66)
    } else if (item.types.length > 0 && item.types[0] === '古建筑') {
      // 塔：层层收分
      Path({ commands: 'M16 3 L21 12 L19 12 L19 16 L23 16 L23 20 L19 20 L19 24 L24 24 L24 29 L8 29 L8 24 L13 24 L13 20 L9 20 L9 16 L13 16 L13 12 L11 12 Z' })
        .width(32).height(32).fill(AppColor.earth).opacity(0.66)
    } else if (item.types.length > 0 && item.types[0] === '墓葬群') {
      // 封土堆
      Path({ commands: 'M3 29 Q16 9 29 29 Z' })
        .width(32).height(32).fill(AppColor.earth).opacity(0.56)
    } else {
      // 聚落：两间坡顶房
      Path({ commands: 'M3 29 L3 19 L9 13 L16 19 L16 29 Z M17 29 L17 20 L24 15 L31 20 L31 29 Z' })
        .width(32).height(32).fill(AppColor.earth).opacity(0.62)
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
        .width(this.CONTENT_LEFT - this.BANK_RIGHT)
        .height(1)
        .backgroundColor(AppColor.earth)
        .position({ x: -(this.CONTENT_LEFT - this.BANK_RIGHT), y: 24 })

      // 岸端落点：线从河岸「长」出来的地方有个点
      Column()
        .width(5)
        .height(5)
        .borderRadius(3)
        .backgroundColor(AppColor.earth)
        .position({ x: -(this.CONTENT_LEFT - this.BANK_RIGHT) - 1, y: 21.5 })

      // 岸边遗迹：压在连接线上，紧贴河道右岸
      Column() {
        this.siteGlyph(item)
      }
      .width(this.GLYPH_W)
      .position({ x: -(this.CONTENT_LEFT - this.GLYPH_LEFT), y: 4 })

    Column({ space: 7 }) {
      Text(item.name)
        .fontSize(20)
        .fontFamily(FontFamily.serif)
        .fontColor(AppColor.textPrimary)
        .letterSpacing(1)
        .width('100%')

      Row({ space: 7 }) {
        Text(item.city)
          .fontSize(11)
          .fontColor(AppColor.seal)
        Text('/')
          .fontSize(11)
          .fontColor(AppColor.divider)
        Text(item.types.length > 0 ? item.types[0] : '')
          .fontSize(11)
          .fontColor(AppColor.textSecondary)
        if (item.level.length > 0) {
          Text('/')
            .fontSize(11)
            .fontColor(AppColor.divider)
          Text(item.level)
            .fontSize(11)
            .fontColor(AppColor.textSecondary)
        }
      }
      .width('100%')

      Text(item.summary)
        .fontSize(13)
        .fontColor(AppColor.textSecondary)
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
        colors: [[AppColor.divider, 0.0], [AppColor.divider, 0.85], [AppColor.background, 1.0]],
      })
  }

  /** 卷末：一条短横线加一点，收住整页 */
  @Builder
  colophon() {
    Column({ space: 10 }) {
      Row()
        .width(28)
        .height(1)
        .backgroundColor(AppColor.divider)
      Text('卷 终')
        .fontSize(10)
        .fontColor(AppColor.textTertiary)
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
            .fontColor(AppColor.danger)
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
    .backgroundColor(AppColor.background)
  }
}
