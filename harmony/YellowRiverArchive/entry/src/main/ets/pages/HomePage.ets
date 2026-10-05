import { common } from '@kit.AbilityKit'
import { AppColor, AppFont, AppSize } from '../constants/Theme'
import { DevProbe, ProbeResult } from '../service/DevProbe'
import { ForceProbe, ForceReport } from '../utils/ForceProbe'

/**
 * 首页。
 *
 * 当前处于 D0-V 阶段，暂时作为"技术验证台"：启动时跑一遍关键技术验证，
 * 结果直接显示在界面上。D1-7 开始实现真正的时间轴与卡片流时，本页会被重写。
 */
@Component
export struct HomePage {
  @State results: ProbeResult[] = []
  @State running: boolean = true
  @State forceReport: ForceReport | undefined = undefined

  private settings: RenderingContextSettings = new RenderingContextSettings(true)
  private canvasCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings)
  private canvasWidth: number = 350
  private canvasHeight: number = 300
  private forceStarted: boolean = false

  aboutToAppear(): void {
    this.runAll()
  }

  private async runAll(): Promise<void> {
    this.running = true
    const collected: ProbeResult[] = []
    const context = this.getUIContext().getHostContext() as common.Context
    collected.push(await DevProbe.probeDistributedKv(context))
    collected.push(await DevProbe.probeRdb(context))
    collected.push(await DevProbe.probeRawfile(context))
    this.results = collected
    this.running = false
  }

  private runForceProbe(): void {
    if (this.forceStarted) {
      return
    }
    this.forceStarted = true
    const report: ForceReport = ForceProbe.run(
      this.canvasCtx,
      this.canvasWidth,
      this.canvasHeight,
      200,
      300,
      60
    )
    this.forceReport = report
  }

  @Builder
  resultCard(item: ProbeResult) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text(item.ok ? '通过' : '失败')
          .fontSize(AppFont.caption)
          .fontColor(item.ok ? '#1F7A3D' : '#B3261E')
          .backgroundColor(item.ok ? '#E3F1E7' : '#FBE3E1')
          .borderRadius(4)
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })

        Text(item.name)
          .fontSize(AppFont.body)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
          .layoutWeight(1)

        Text(`${item.ms}ms`)
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textTertiary)
      }
      .width('100%')

      Text(item.detail)
        .fontSize(AppFont.caption)
        .fontColor(AppColor.textSecondary)
        .width('100%')
    }
    .width('100%')
    .padding(AppSize.cardGap)
    .backgroundColor(AppColor.surface)
    .borderRadius(AppSize.cardRadius)
  }

  @Builder
  forceCard() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        if (this.forceReport !== undefined) {
          Text(this.forceReport.smooth ? '通过' : '偏慢')
            .fontSize(AppFont.caption)
            .fontColor(this.forceReport.smooth ? '#1F7A3D' : '#B3261E')
            .backgroundColor(this.forceReport.smooth ? '#E3F1E7' : '#FBE3E1')
            .borderRadius(4)
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
        }

        Text('D0V-3 力导向布局性能')
          .fontSize(AppFont.body)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
          .layoutWeight(1)

        if (this.forceReport !== undefined) {
          Text(`${this.forceReport.msPerFrame}ms/帧`)
            .fontSize(AppFont.caption)
            .fontColor(AppColor.textTertiary)
        }
      }
      .width('100%')

      Canvas(this.canvasCtx)
        .width('100%')
        .height(this.canvasHeight)
        .backgroundColor('#FBF8F3')
        .borderRadius(8)
        .onReady(() => {
          this.runForceProbe()
        })

      if (this.forceReport !== undefined) {
        Text(
          `${this.forceReport.nodeCount} 节点 / ${this.forceReport.edgeCount} 连边 ｜ ` +
            `渲染 ${this.forceReport.frames} 帧耗时 ${this.forceReport.totalMs}ms ｜ ` +
            `折算 ${Math.round(1000 / this.forceReport.msPerFrame)}fps`
        )
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textSecondary)
          .width('100%')
      } else {
        Text('渲染中…')
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textTertiary)
          .width('100%')
      }
    }
    .width('100%')
    .padding(AppSize.cardGap)
    .backgroundColor(AppColor.surface)
    .borderRadius(AppSize.cardRadius)
  }

  build() {
    Scroll() {
      Column({ space: AppSize.cardGap }) {
        Row() {
          Text('技术验证台')
            .fontSize(AppFont.title)
            .fontWeight(FontWeight.Medium)
            .fontColor(AppColor.textPrimary)
            .layoutWeight(1)

          Text('D0-V')
            .fontSize(AppFont.caption)
            .fontColor(AppColor.primary)
            .backgroundColor('#F0E6DA')
            .borderRadius(6)
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
        }
        .width('100%')

        if (this.running) {
          Text('验证进行中…')
            .fontSize(AppFont.body)
            .fontColor(AppColor.textSecondary)
            .margin({ top: 24 })
        }

        ForEach(
          this.results,
          (item: ProbeResult) => {
            this.resultCard(item)
          },
          (item: ProbeResult) => item.name
        )

        this.forceCard()
      }
      .width('100%')
      .padding(AppSize.pagePadding)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .backgroundColor(AppColor.background)
  }
}
