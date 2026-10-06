import { common } from '@kit.AbilityKit'
import { router } from '@kit.ArkUI'

import { CORE_ERAS, type Favorite, type Note, type Progress, type Tag } from '../shared'
import { AppColor, AppFont, AppSize } from '../constants/Theme'
import { HeritageDao } from '../service/HeritageDao'
import { PersonalDao } from '../service/PersonalDao'
import { SyncService, type SyncSummary } from '../service/sync/SyncService'

/** 收藏项的展示形状（把 id 补成可读的名称） */
interface FavoriteView {
  readonly id: string
  readonly targetId: string
  readonly name: string
  readonly city: string
  readonly era: string
  readonly cover: string
  readonly createdAt: number
}

/** 带条目名的笔记 */
interface NoteView {
  readonly id: string
  readonly targetId: string
  readonly itemName: string
  readonly content: string
  readonly updatedAt: number
}

/**
 * 我的档案：学习进度 / 收藏 / 笔记 / 标签。
 *
 * 数据全部来自本机（离线优先），不请求云侧 —— 这一页在任何网络状态下都必须可用。
 * 见 docs/开发TODO.md D4-2。
 */
@Component
export struct ProfilePage {
  @State progress: Progress[] = []
  @State overallDone: number = 0
  @State overallTotal: number = 0
  @State favorites: FavoriteView[] = []
  @State notes: NoteView[] = []
  @State tags: Tag[] = []
  @State loaded: boolean = false
  @State activePane: number = 0
  // ---- 同步 ----
  @State syncLines: string[] = []
  @State pairCode: string = ''
  @State joinCode: string = ''
  @State syncBusy: boolean = false
  @State syncMessage: string = ''

  aboutToAppear(): void {
    this.load()
  }

  private async load(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.Context
      await HeritageDao.ready(context)

      this.progress = await PersonalDao.progressByEra(context, CORE_ERAS)

      let done: number = 0
      let total: number = 0
      for (const p of this.progress) {
        done += p.visited
        total += p.total
      }
      this.overallDone = done
      this.overallTotal = total

      // 收藏：把 targetId 补成条目名与归属信息
      const rawFavorites: Favorite[] = await PersonalDao.listFavorites(context)
      const views: FavoriteView[] = []
      for (const fav of rawFavorites) {
        const item = HeritageDao.detail(fav.targetId)
        if (item === undefined) {
          continue
        }
        views.push({
          id: fav.id,
          targetId: fav.targetId,
          name: item.name,
          city: item.city,
          era: item.era,
          cover: item.images.length > 0 ? item.images[0].url : '',
          createdAt: fav.createdAt,
        })
      }
      this.favorites = views

      const rawNotes: Note[] = await PersonalDao.listNotes(context)
      const noteViews: NoteView[] = []
      for (const note of rawNotes) {
        const item = HeritageDao.detail(note.targetId)
        noteViews.push({
          id: note.id,
          targetId: note.targetId,
          itemName: item !== undefined ? item.name : note.targetId,
          content: note.content,
          updatedAt: note.updatedAt,
        })
      }
      this.notes = noteViews

      this.tags = await PersonalDao.listTags(context)
      await this.refreshSyncStatus()
    } catch (err) {
      // 页面降级为空态，不弹错
    }
    this.loaded = true
  }

  private openItem(id: string): void {
    router.pushUrl({ url: 'pages/DetailPage', params: { id } })
  }

  private async refreshSyncStatus(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.Context
      await SyncService.init(context)
      this.syncLines = await SyncService.channelReport(context)
    } catch (err) {
      this.syncLines = ['状态获取失败']
    }
  }

  /** 本机设备名：用「型号-短 id」，两台设备在列表里能分辨出来 */
  private async deviceLabel(context: common.Context): Promise<string> {
    const id: string = await PersonalDao.getDeviceId(context)
    return id.slice(0, 6)
  }

  private async onCreatePairing(): Promise<void> {
    if (this.syncBusy) {
      return
    }
    this.syncBusy = true
    this.syncMessage = '正在生成配对码…'
    try {
      const context = this.getUIContext().getHostContext() as common.Context
      const label: string = await this.deviceLabel(context)
      const result = await SyncService.createPairing(context, `设备-${label}`)
      this.pairCode = result.code
      this.syncMessage = result.message
      await this.refreshSyncStatus()
    } catch (err) {
      this.syncMessage = '生成失败'
    }
    this.syncBusy = false
  }

  private async onJoinPairing(): Promise<void> {
    const code: string = this.joinCode.trim()
    if (code.length === 0 || this.syncBusy) {
      return
    }
    this.syncBusy = true
    this.syncMessage = '正在配对…'
    try {
      const context = this.getUIContext().getHostContext() as common.Context
      const label: string = await this.deviceLabel(context)
      const result = await SyncService.joinPairing(context, code, `设备-${label}`)
      this.syncMessage = result.message
      if (result.ok) {
        this.joinCode = ''
        await this.refreshSyncStatus()
      }
    } catch (err) {
      this.syncMessage = '配对异常'
    }
    this.syncBusy = false
  }

  private async onResetCursor(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.Context
      await SyncService.resetCursor(context)
      this.syncMessage = '同步游标已重置，下次同步会重新推送全部本地数据'
    } catch (err) {
      this.syncMessage = '重置失败'
    }
  }

  private async onSync(): Promise<void> {
    if (this.syncBusy) {
      return
    }
    this.syncBusy = true
    this.syncMessage = '正在同步…'
    try {
      const context = this.getUIContext().getHostContext() as common.Context
      const summary: SyncSummary = await SyncService.sync(context)
      this.syncMessage = summary.outcome.message
      await this.load()
    } catch (err) {
      this.syncMessage = '同步异常'
    }
    this.syncBusy = false
  }

  @Builder
  syncCard() {
    Column({ space: 10 }) {
      Text('跨设备同步')
        .fontSize(AppFont.heading)
        .fontWeight(FontWeight.Medium)
        .fontColor(AppColor.textPrimary)
        .width('100%')

      ForEach(
        this.syncLines,
        (line: string) => {
          Text(line)
            .fontSize(11)
            .fontColor(AppColor.textSecondary)
            .width('100%')
        },
        (line: string) => line
      )

      Row({ space: 8 }) {
        Button(this.pairCode.length > 0 ? `配对码 ${this.pairCode}` : '生成配对码')
          .fontSize(AppFont.caption)
          .fontColor(AppColor.surface)
          .backgroundColor(AppColor.primary)
          .borderRadius(8)
          .layoutWeight(1)
          .onClick(() => {
            this.onCreatePairing()
          })
        Button(this.syncBusy ? '…' : '立即同步')
          .fontSize(AppFont.caption)
          .fontColor(AppColor.primary)
          .backgroundColor(AppColor.surface)
          .borderWidth(1)
          .borderColor(AppColor.primary)
          .borderRadius(8)
          .layoutWeight(1)
          .onClick(() => {
            this.onSync()
          })
      }
      .width('100%')

      Row({ space: 8 }) {
        TextInput({ text: this.joinCode, placeholder: '输入另一台设备的 6 位配对码' })
          .fontSize(AppFont.caption)
          .backgroundColor(AppColor.background)
          .borderRadius(8)
          .type(InputType.Number)
          .maxLength(6)
          .layoutWeight(1)
          .onChange((value: string) => {
            this.joinCode = value
          })
        Button('重置游标')
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textTertiary)
          .backgroundColor(AppColor.background)
          .borderRadius(8)
          .onClick(() => {
            this.onResetCursor()
          })
        Button('加入')
          .fontSize(AppFont.caption)
          .fontColor(AppColor.surface)
          .backgroundColor(this.joinCode.trim().length === 6 ? AppColor.primary : AppColor.textTertiary)
          .borderRadius(8)
          .onClick(() => {
            this.onJoinPairing()
          })
      }
      .width('100%')

      if (this.syncMessage.length > 0) {
        Text(this.syncMessage)
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textPrimary)
          .width('100%')
          .padding(8)
          .backgroundColor(AppColor.background)
          .borderRadius(8)
      }
    }
    .width('100%')
    .padding(AppSize.pagePadding)
    .backgroundColor(AppColor.surface)
    .borderRadius(AppSize.cardRadius)
  }

  @Builder
  progressCard() {
    Column({ space: 10 }) {
      Row() {
        Text('学习进度')
          .fontSize(AppFont.heading)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
          .layoutWeight(1)
        Text(`${this.overallDone} / ${this.overallTotal}`)
          .fontSize(AppFont.body)
          .fontColor(AppColor.primary)
      }
      .width('100%')

      Progress({
        value: this.overallTotal === 0 ? 0 : (this.overallDone / this.overallTotal) * 100,
        total: 100,
        type: ProgressType.Linear,
      })
        .color(AppColor.primary)
        .width('100%')

      // 按时代分段：只有读到过的时代才显示，避免一屏全是 0/0
      ForEach(
        this.progress,
        (p: Progress) => {
          if (p.total > 0) {
            Row() {
              Text(p.era)
                .fontSize(AppFont.caption)
                .fontColor(AppColor.textSecondary)
                .width(56)
              Progress({
                value: p.total === 0 ? 0 : (p.visited / p.total) * 100,
                total: 100,
                type: ProgressType.Linear,
              })
                .color(p.visited > 0 ? AppColor.primaryLight : AppColor.divider)
                .layoutWeight(1)
              Text(`${p.visited}/${p.total}`)
                .fontSize(AppFont.caption)
                .fontColor(AppColor.textTertiary)
                .width(48)
                .textAlign(TextAlign.End)
            }
            .width('100%')
          }
        },
        (p: Progress) => p.era
      )
    }
    .width('100%')
    .padding(AppSize.pagePadding)
    .backgroundColor(AppColor.surface)
    .borderRadius(AppSize.cardRadius)
  }

  @Builder
  favoriteList() {
    Column({ space: 8 }) {
      if (this.favorites.length === 0) {
        Text('还没有收藏。在档案详情页点「收藏」即可加入。')
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textTertiary)
          .width('100%')
      } else {
        ForEach(
          this.favorites,
          (fav: FavoriteView) => {
            Row({ space: 10 }) {
              Column({ space: 2 }) {
                Text(fav.name)
                  .fontSize(AppFont.body)
                  .fontColor(AppColor.textPrimary)
                  .width('100%')
                Text(`${fav.city} · ${fav.era} · 收藏于 ${PersonalDao.formatTime(fav.createdAt)}`)
                  .fontSize(11)
                  .fontColor(AppColor.textTertiary)
                  .width('100%')
              }
              .layoutWeight(1)

              Text('查看')
                .fontSize(AppFont.caption)
                .fontColor(AppColor.primary)
            }
            .width('100%')
            .padding(10)
            .backgroundColor(AppColor.background)
            .borderRadius(8)
            .onClick(() => {
              this.openItem(fav.targetId)
            })
          },
          (fav: FavoriteView) => fav.id
        )
      }
    }
    .width('100%')
  }

  @Builder
  noteList() {
    Column({ space: 8 }) {
      if (this.notes.length === 0) {
        Text('还没有笔记。在档案详情页写下第一条。')
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textTertiary)
          .width('100%')
      } else {
        ForEach(
          this.notes,
          (note: NoteView) => {
            Column({ space: 4 }) {
              Row() {
                Text(note.itemName)
                  .fontSize(AppFont.caption)
                  .fontColor(AppColor.primary)
                  .layoutWeight(1)
                Text(PersonalDao.formatTime(note.updatedAt))
                  .fontSize(11)
                  .fontColor(AppColor.textTertiary)
              }
              .width('100%')
              Text(note.content)
                .fontSize(AppFont.body)
                .fontColor(AppColor.textPrimary)
                .width('100%')
            }
            .width('100%')
            .padding(10)
            .backgroundColor(AppColor.background)
            .borderRadius(8)
            .onClick(() => {
              this.openItem(note.targetId)
            })
          },
          (note: NoteView) => note.id
        )
      }
    }
    .width('100%')
  }

  @Builder
  tagList() {
    Column({ space: 8 }) {
      if (this.tags.length === 0) {
        Text('还没有标签。标签用于给收藏分组，可在同步后跨设备共用。')
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textTertiary)
          .width('100%')
      } else {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(
            this.tags,
            (tag: Tag) => {
              Text(tag.name)
                .fontSize(AppFont.caption)
                .fontColor(AppColor.primary)
                .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                .backgroundColor(AppColor.background)
                .borderRadius(12)
                .margin({ right: 6, bottom: 6 })
            },
            (tag: Tag) => tag.id
          )
        }
        .width('100%')
      }
    }
    .width('100%')
  }

  build() {
    Column() {
      Text('我的档案')
        .fontSize(AppFont.title)
        .fontWeight(FontWeight.Medium)
        .fontColor(AppColor.textPrimary)
        .width('100%')
        .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding, top: 16, bottom: 12 })

      Scroll() {
        Column({ space: AppSize.cardGap }) {
          this.progressCard()

          this.syncCard()

          Column() {
            Tabs({ barPosition: BarPosition.Start, index: this.activePane }) {
              TabContent() {
                this.favoriteList()
              }
              .tabBar(`收藏 ${this.favorites.length}`)

              TabContent() {
                this.noteList()
              }
              .tabBar(`笔记 ${this.notes.length}`)

              TabContent() {
                this.tagList()
              }
              .tabBar(`标签 ${this.tags.length}`)
            }
            .barMode(BarMode.Fixed)
            .height(320)
          }
          .width('100%')
          .padding(AppSize.pagePadding)
          .backgroundColor(AppColor.surface)
          .borderRadius(AppSize.cardRadius)
        }
        .width('100%')
        .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding, bottom: 16 })
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppColor.background)
  }
}
