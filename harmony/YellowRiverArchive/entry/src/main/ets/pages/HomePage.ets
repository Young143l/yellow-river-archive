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
  /**
   * 河流背景图规格。
   *
   * 河道的视觉由豆包生成的 5 张水墨背景图承担，代码只负责循环堆叠 + 水纹动效。
   * 为什么要缩放到 228vp：豆包稿里河道最宽处占 50% 屏宽，直接铺满会压到正文；
   * 等比缩放到 228vp 后河道正好落在 114vp 以内，右侧 132vp 用纸色续上
   * （背景图右缘本来就是纯纸色带洒金，接缝看不出来）。
   *
   * 1080 × 2400 的源图等比缩放到 228 × 507。
   */
  private readonly BG_W: number = 228
  private readonly BG_H: number = 507
  /** 水纹画布宽度：与河道可见宽度一致 */
  private readonly RIVER_W: number = 114
  /** 正文起始位置：河岸 114 + 8px 呼吸 */
  private readonly CONTENT_LEFT: number = 122
  /** 水纹横向范围（避开心滩与滩地） */
  private readonly RIPPLE_X0: number = 22
  private readonly RIPPLE_X1: number = 100

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
  private ripple(x: number, y: number, len: number, dir: number): void {
    this.ctx.beginPath()
    this.ctx.moveTo(x, y)
    this.ctx.quadraticCurveTo(x + len / 2, y + 1.9 * dir, x + len, y)
    this.ctx.stroke()
  }

  /**
   * 水纹叠层。
   *
   * 河床是静态背景图，只有这一层在动 —— 观感是「河不动、水在流」，
   * 比让整张贴图滚动正确得多（贴图滚动会和内容滚动打架）。
   *
   * 横向限制在 RIPPLE_X0..RIPPLE_X1：背景图里的水道集中在这一带，
   * 画到外面就会落在心滩或滩地上。
   */
  private drawRipples(): void {
    const h: number = this.ctx.height
    if (h <= 0) {
      return
    }
    this.ctx.clearRect(0, 0, this.ctx.width, h)
    this.ctx.lineWidth = 1.4
    this.ctx.lineCap = 'round'

    const drift: number = (this.phase * 9) % 18
    const span: number = this.RIPPLE_X1 - this.RIPPLE_X0

    let k: number = 0
    let y: number = -6
    while (y <= h) {
      const yy: number = y + drift
      // 每条水纹的位置按行号伪随机，避免排成网格
      const seed: number = k * 37
      const len: number = 4 + (seed % 6)
      const x: number = this.RIPPLE_X0 + ((seed * 29) % 100) / 100 * span
      const alpha: number = 0.22 + (seed % 4) / 30
      this.ctx.strokeStyle = `rgba(240, 250, 253, ${alpha})`
      this.ripple(x, yy, len, seed % 2 === 0 ? 1 : -1)
      k += 1
      y += 14 + ((k * 31) % 16)
    }
  }

  /**
   * 估算内容总高度。
   *
   * 不用 onAreaChange 测量：实测把 Column 放在 Stack 里时，
   * onAreaChange 报回的值不触发重渲染，背景图永远只铺第一张
   * （截图里河流滚到一半就断了）。
   *
   * 首页内容是确定结构 —— 卷首 + 每个时代一个标题 + 每条一个条目 + 卷末 ——
   * 按固定行高估出来足够准，也不受布局时机影响。
   */
  private estimateHeight(): number {
    let items: number = 0
    for (const g of this.groups) {
      items += g.items.length
    }
    const MASTHEAD: number = 200
    const GROUP_HEADER: number = 92
    const ITEM: number = 232
    const COLOPHON: number = 110
    return MASTHEAD + this.groups.length * GROUP_HEADER + items * ITEM + COLOPHON
  }

  /**
   * 背景图路径。
   *
   * 5 张原稿在构建期就被**离屏合成为一张 684×6000 的长图**
   * （上下各 400px 大幅淡入淡出衔接），运行时只显示这一张。
   *
   * 为什么不在 ArkUI 里拼接：曾经试过 11vp 的交叉溶解，接缝处仍有一条
   * 肉眼可见的横向雾带 —— 短距离的溶解盖不住两图河道位置的错位。
   * 把合成放到离屏、把过渡拉到 400px，才能把错位真正抹平。
   *
   * 1080×6000 全屏宽（左 684px 是河 + 纸，右 396px 用镜像纸面续上）。
   * 为什么要续到全宽：只铺 228vp 时，右侧 App 底色（#F2EDE0）与图片纸色
   * （#F4EADB）差了几个色阶，交界处能看出一条竖线。铺满就没有边界了。
   * 数据增长后需要重新合成一张更高的。
   */
  private backgroundSource(): string {
    return 'img/river-bg.webp'
  }

  private startRiver(): void {
    if (!this.riverReady || this.timer !== -1) {
      return
    }
    if (this.estimateHeight() > 9000) {
      this.drawRipples()
      return
    }
    this.timer = setInterval(() => {
      this.phase += 0.022
      this.drawRipples()
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

  /** 一条遗址 */
  /**
   * 一条遗址。
   *
   * 移除了原先的「岸边简笔图形 + 连接线」：河流背景图里已经有完整的岸线，
   * 再叠一个 26px 的线稿会与水墨笔触打架。文字直接排在河岸右侧。
   */
  @Builder
  itemEntry(item: HeritageSummary) {
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
          Stack({ alignContent: Alignment.TopStart }) {
            // ---- 背景层：5 张水墨河流图循环堆叠 ----
            // 放在 Scroll 内部才会随内容滚动；放在外面会固定在视口里（踩过）。
            // Cover：图比内容高时裁掉底部多余部分，宽度按 684/3=228vp 自然对齐，
            // 不会横向变形。
            // 高度必须写 '100%' 而不是估算值 —— 写死高度会让 Stack 被图片撑高，
            // 内容读完还能继续往下滑一截空白。'100%' 跟随 Stack，
            // 而 Stack 的高度由正文列决定。
            Image($rawfile(this.backgroundSource()))
              .width('100%')
              .height('100%')
              .objectFit(ImageFit.Cover)
              .position({ x: 0, y: 0 })

            // ---- 水纹层：只有白色短弧，透明底 ----
            Canvas(this.ctx)
              .width(this.RIVER_W)
              .height('100%')
              .position({ x: 0, y: 0 })
              .onReady(() => {
                this.riverReady = true
                this.drawRipples()
                this.startRiver()
              })

            // ---- 正文 ----
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
