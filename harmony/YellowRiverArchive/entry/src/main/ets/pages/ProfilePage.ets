import { common } from '@kit.AbilityKit'
import { router } from '@kit.ArkUI'

import { CORE_ERAS, type Favorite, type Note, type Progress, type Tag } from '../shared'
import { AppColor, AppFont, AppSize } from '../constants/Theme'
import { HeritageDao } from '../service/HeritageDao'
import { PersonalDao } from '../service/PersonalDao'

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
    } catch (err) {
      // 页面降级为空态，不弹错
    }
    this.loaded = true
  }

  private openItem(id: string): void {
    router.pushUrl({ url: 'pages/DetailPage', params: { id } })
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
