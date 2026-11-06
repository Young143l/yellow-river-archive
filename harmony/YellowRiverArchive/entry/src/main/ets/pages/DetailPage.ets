import { common } from '@kit.AbilityKit'
import { router } from '@kit.ArkUI'

import { SECTION_LABELS, type HeritageItem, type Note } from '../shared'
import { AppColor, AppFont, AppSize, FontFamily } from '../constants/Theme'
import { HeritageDao, type RelatedItem } from '../service/HeritageDao'
import { PersonalDao } from '../service/PersonalDao'
import { MarkdownView } from '../components/MarkdownView'
import { Recommender } from '../utils/Recommender'

/** 路由参数 */
interface DetailParams {
  readonly id: string
}

/**
 * 详情页：五层内容 + 关联图谱，共六个分区。
 * 见 docs/开发TODO.md D1-9。
 */
@Entry
@Component
struct DetailPage {
  @State item: HeritageItem | undefined = undefined
  @State related: RelatedItem[] = []
  @State loading: boolean = true
  @State error: string = ''
  @State activeIndex: number = 0
  // ---- 个人记录 ----
  @State favorited: boolean = false
  @State notes: Note[] = []
  @State noteDraft: string = ''
  @State saving: boolean = false
  /** 笔记编辑面板是否展开 */
  @State editing: boolean = false
  /**
   * 光标位置。
   *
   * TextAreaController 只有 caretPosition(value) 这个**写入**接口，没有读取方法，
   * 所以靠 onTextSelectionChange 自己记一份，工具条才能在光标处插入语法。
   */
  @State caret: number = 0

  private itemId: string = ''
  private taController: TextAreaController = new TextAreaController()

  aboutToAppear(): void {
    const params = router.getParams() as DetailParams
    if (params !== undefined && params.id !== undefined) {
      this.itemId = params.id
    }
    this.load()
  }

  private async load(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.Context
      await HeritageDao.ready(context)
      this.item = HeritageDao.detail(this.itemId)
      if (this.item === undefined) {
        this.error = `未找到档案：${this.itemId}`
      } else {
        // 行为画像：收藏强信号、浏览弱信号。没有行为时 related 自动退回纯内容相似度
        const favorites = await PersonalDao.listFavorites(context)
        const visits = await PersonalDao.listVisits(context)
        const recommender: Recommender | null =
          favorites.length + visits.length > 0
            ? Recommender.build(HeritageDao.all(), favorites, visits)
            : null
        this.related = await HeritageDao.related(context, this.itemId, recommender)
      }
      await this.loadPersonal()
    } catch (err) {
      this.error = `加载失败：${(err as Error).message}`
    }
    this.loading = false
  }

  /** 读收藏状态与笔记 */
  private async loadPersonal(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.Context
      this.favorited = await PersonalDao.isFavorite(context, 'site', this.itemId)
      this.notes = await PersonalDao.listNotes(context, this.itemId)
      // 打开详情页即视为已读（进度统计的数据来源）
      await PersonalDao.recordVisit(context, this.itemId)
    } catch (err) {
      // 个人数据读失败不该阻断档案浏览
    }
  }

  /**
   * 通知「我的」页重新拉取个人数据。
   *
   * 五个主页面挂在 Index 的 Tabs 里，只创建一次，aboutToAppear 也只跑一次。
   * 从详情页返回时切回「我的」，它不会重新查库，笔记/收藏就停在旧值上。
   * 用一个 AppStorage 计数器把变更广播出去（ProfilePage 用 @Watch 监听）。
   */
  private bumpPersonalVersion(): void {
    AppStorage.setOrCreate<number>('personalVersion', (AppStorage.get<number>('personalVersion') ?? 0) + 1)
  }

  private async toggleFavorite(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.Context
      this.favorited = await PersonalDao.toggleFavorite(context, 'site', this.itemId)
      this.bumpPersonalVersion()
    } catch (err) {
      this.error = `收藏失败：${(err as Error).message}`
    }
  }

  private openEditor(): void {
    this.editing = true
  }

  /** 在光标处插入 Markdown 语法。粗体/代码传成对的符号，光标自然落在中间 */
  private insertMarkdown(prefix: string, suffix: string): void {
    const at: number = Math.min(this.caret, this.noteDraft.length)
    this.noteDraft = this.noteDraft.slice(0, at) + prefix + suffix + this.noteDraft.slice(at)
    this.caret = at + prefix.length
    this.taController.caretPosition(this.caret)
  }

  private async submitNote(): Promise<void> {
    const content: string = this.noteDraft.trim()
    if (content.length === 0 || this.saving) {
      return
    }
    this.saving = true
    try {
      const context = this.getUIContext().getHostContext() as common.Context
      await PersonalDao.addNote(context, 'site', this.itemId, content)
      this.noteDraft = ''
      this.caret = 0
      this.notes = await PersonalDao.listNotes(context, this.itemId)
      this.bumpPersonalVersion()
      this.editing = false
    } catch (err) {
      this.error = `保存笔记失败：${(err as Error).message}`
    }
    this.saving = false
  }

  private async removeNote(id: string): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.Context
      await PersonalDao.deleteNote(context, id)
      this.notes = await PersonalDao.listNotes(context, this.itemId)
      this.bumpPersonalVersion()
    } catch (err) {
      this.error = `删除笔记失败：${(err as Error).message}`
    }
  }

  private openDetail(id: string): void {
    router.pushUrl({ url: 'pages/DetailPage', params: { id } })
  }

  @Builder
  sectionText(text: string) {
    Text(text)
      .fontSize(AppFont.body)
      .fontColor(AppColor.textPrimary)
      .lineHeight(24)
      .width('100%')
  }

  /**
   * 个人记录卡片：收藏按钮 + 笔记。
   *
   * 放在头部下方而不是作为第六个 Tab：五个 Tab 是「公共档案内容」，
   * 个人记录是「我对此条目的动作」，性质不同，混进 Tab 会混淆两者的边界。
   */
  @Builder
  personalCard() {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        Button(this.favorited ? '已收藏' : '收藏')
          .fontSize(AppFont.body)
          .fontColor(this.favorited ? AppColor.surface : AppColor.primary)
          .backgroundColor(this.favorited ? AppColor.primary : AppColor.surface)
          .borderWidth(1)
          .borderColor(AppColor.primary)
          .borderRadius(AppSize.cardRadius)
          .layoutWeight(1)
          .onClick(() => {
            this.toggleFavorite()
          })

        Text(`笔记 ${this.notes.length}`)
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textSecondary)
          .padding({ left: 12, right: 12 })
      }
      .width('100%')

      // 入口：看起来像一张待写的纸条。原先是单行输入框 + 添加按钮，
      // 写不了第二行 —— 笔记变成一行命令，而不是笔记。
      Row({ space: 8 }) {
        Text('写一条笔记…')
          .fontSize(AppFont.body)
          .fontFamily(FontFamily.serif)
          .fontColor(AppColor.textTertiary)
          .layoutWeight(1)
        Text('＋')
          .fontSize(AppFont.body)
          .fontColor(AppColor.primary)
      }
      .width('100%')
      .height(44)
      .padding({ left: 14, right: 14 })
      .backgroundColor(AppColor.background)
      .borderRadius(12)
      .borderWidth(1)
      .borderColor(AppColor.hairlineWarm)
      .onClick(() => {
        this.openEditor()
      })

      if (this.notes.length === 0) {
        Text('还没有笔记')
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textTertiary)
          .width('100%')
      } else {
        ForEach(
          this.notes,
          (note: Note) => {
            Row({ space: 8 }) {
              Column({ space: 4 }) {
                // 按 Markdown 渲染：编辑面板里点的粗体、标题、列表要看得出效果，
                // 否则用户看到的是一对星号
                MarkdownView({ content: note.content, baseSize: AppFont.caption })
                  .width('100%')

                Text(PersonalDao.formatTime(note.updatedAt))
                  .fontSize(11)
                  .fontColor(AppColor.textTertiary)
                  .width('100%')
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Text('删除')
                .fontSize(AppFont.caption)
                .fontColor(AppColor.textTertiary)
                .onClick(() => {
                  this.removeNote(note.id)
                })
            }
            .width('100%')
            .padding(8)
            .backgroundColor(AppColor.background)
            .borderRadius(8)
          },
          (note: Note) => note.id
        )
      }
    }
    .width('100%')
    .padding(AppSize.pagePadding)
    .backgroundColor(AppColor.surface)
    .borderRadius(AppSize.cardRadius)
  }

  @Builder
  sectionEmpty(hint: string) {
    Text(hint)
      .fontSize(AppFont.caption)
      .fontColor(AppColor.textTertiary)
      .width('100%')
      .padding({ top: 12, bottom: 12 })
  }

  @Builder
  introSection(item: HeritageItem) {
    Column({ space: AppSize.cardGap }) {
      // 暂不展示配图：数据量还不足以支撑全套实拍授权，
      // 版式先按纯文字排，配图位留着（schema 里的 images 字段照旧保留）
      this.sectionText(item.intro)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  archaeologySection(item: HeritageItem) {
    Column({ space: AppSize.cardGap }) {
      this.sectionText(item.archaeology)

      if (item.artifacts.length > 0) {
        Text('出土文物')
          .fontSize(AppFont.body)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
          .width('100%')

        ForEach(
          item.artifacts,
          (a: ArtifactPayload) => {
            Column({ space: 4 }) {
              Text(a.name)
                .fontSize(AppFont.body)
                .fontColor(AppColor.primary)
                .width('100%')
              Text(a.desc)
                .fontSize(AppFont.caption)
                .fontColor(AppColor.textSecondary)
                .lineHeight(19)
                .width('100%')
              if (a.museum !== undefined) {
                Text(`藏于 ${a.museum}`)
                  .fontSize(11)
                  .fontColor(AppColor.textTertiary)
                  .width('100%')
              }
            }
            .width('100%')
            .padding(AppSize.cardGap)
            .backgroundColor(AppColor.surface)
            .borderRadius(AppSize.cardRadius)
          },
          (a: ArtifactPayload) => a.id
        )
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  eventsSection(item: HeritageItem) {
    Column({ space: AppSize.cardGap }) {
      if (item.events.length === 0) {
        this.sectionEmpty('暂无收录的历史事件')
      }
      ForEach(
        item.events,
        (e: EventPayload) => {
          Row({ space: AppSize.cardGap }) {
            Text(e.year)
              .fontSize(AppFont.caption)
              .fontColor(AppColor.surface)
              .backgroundColor(AppColor.primary)
              .borderRadius(6)
              .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            Column({ space: 4 }) {
              Text(e.title)
                .fontSize(AppFont.body)
                .fontColor(AppColor.textPrimary)
                .width('100%')
              Text(e.desc)
                .fontSize(AppFont.caption)
                .fontColor(AppColor.textSecondary)
                .lineHeight(19)
                .width('100%')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
          .padding(AppSize.cardGap)
          .backgroundColor(AppColor.surface)
          .borderRadius(AppSize.cardRadius)
        },
        (e: EventPayload) => `${e.year}-${e.title}`
      )
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  poemsSection(item: HeritageItem) {
    Column({ space: AppSize.cardGap }) {
      if (item.poems.length === 0) {
        this.sectionEmpty('该遗址暂未收录关联诗词（古代尚不知其存在）')
      }
      ForEach(
        item.poems,
        (p: PoemPayload) => {
          Column({ space: 6 }) {
            Text(`${p.title}　${p.dynasty}·${p.author}`)
              .fontSize(AppFont.caption)
              .fontColor(AppColor.textTertiary)
              .width('100%')
            Text(p.content)
              .fontSize(AppFont.body)
              .fontColor(AppColor.textPrimary)
              .lineHeight(26)
              .width('100%')
            if (p.note !== undefined) {
              Text(p.note)
                .fontSize(11)
                .fontColor(AppColor.primary)
                .lineHeight(17)
                .width('100%')
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding(AppSize.cardGap)
          .backgroundColor(AppColor.surface)
          .borderRadius(AppSize.cardRadius)
        },
        (p: PoemPayload) => p.title
      )
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  travelSection(item: HeritageItem) {
    Column({ space: 8 }) {
      if (item.travel === undefined) {
        this.sectionEmpty('暂无文旅信息')
      } else {
        if (item.travel.hours !== undefined) {
          this.infoRow('开放时间', item.travel.hours)
        }
        if (item.travel.ticket !== undefined) {
          this.infoRow('门票', item.travel.ticket)
        }
        if (item.travel.best !== undefined) {
          this.infoRow('推荐季节', item.travel.best)
        }
        ForEach(
          item.travel.tips,
          (tip: string) => {
            this.infoRow('提示', tip)
          },
          (tip: string) => tip
        )
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  infoRow(label: string, value: string) {
    Row({ space: AppSize.cardGap }) {
      Text(label)
        .fontSize(AppFont.caption)
        .fontColor(AppColor.textTertiary)
        .width(64)
      Text(value)
        .fontSize(AppFont.caption)
        .fontColor(AppColor.textPrimary)
        .lineHeight(20)
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding(AppSize.cardGap)
    .backgroundColor(AppColor.surface)
    .borderRadius(AppSize.cardRadius)
  }

  @Builder
  graphSection() {
    Column({ space: AppSize.cardGap }) {
      if (this.related.length === 0) {
        this.sectionEmpty('暂无关联条目')
      }
      ForEach(
        this.related,
        (r: RelatedItem) => {
          Row({ space: AppSize.cardGap }) {
            Column({ space: 4 }) {
              Text(r.name)
                .fontSize(AppFont.body)
                .fontColor(AppColor.textPrimary)
                .width('100%')
              Text(r.reason)
                .fontSize(11)
                .fontColor(AppColor.textTertiary)
                .width('100%')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Text(r.score.toFixed(2))
              .fontSize(11)
              .fontColor(AppColor.primary)
          }
          .width('100%')
          .padding(AppSize.cardGap)
          .backgroundColor(AppColor.surface)
          .borderRadius(AppSize.cardRadius)
          .onClick(() => {
            this.openDetail(r.id)
          })
        },
        (r: RelatedItem) => r.id
      )
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  header(item: HeritageItem) {
    Column({ space: 8 }) {
      // 顶部题名块：纯色底 + 居中宋体题名，不依赖任何图片资源。
      // 最早那版的形态 —— 数据还没有实拍图时，与其放一张示意图，
      // 不如只留一块安静的字，不误导也不抢正文。
      Column() {
        Text(item.name)
          .fontSize(30)
          .fontFamily(FontFamily.serifBold)
          .fontColor(AppColor.textPrimary)
          .textAlign(TextAlign.Center)
          .letterSpacing(4)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .height(200)
      .justifyContent(FlexAlign.Center)
      .padding({ left: 24, right: 24 })
      .backgroundColor(AppColor.surface)
      .borderRadius(AppSize.cardRadius)
      .borderWidth(1)
      .borderColor(AppColor.hairlineWarm)

      Row({ space: 8 }) {
        Text(`${item.city} · ${item.era}`)
          .fontSize(AppFont.caption)
          .fontColor(AppColor.primary)
        ForEach(
          item.types,
          (t: string) => {
            Text(t)
              .fontSize(11)
              .fontColor(AppColor.textSecondary)
              .backgroundColor(AppColor.divider)
              .borderRadius(4)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          },
          (t: string) => t
        )
        if (item.level !== undefined) {
          Text(item.level)
            .fontSize(11)
            .fontColor(AppColor.textTertiary)
        }
      }
      .width('100%')

      Text(item.summary)
        .fontSize(AppFont.body)
        .fontColor(AppColor.textSecondary)
        .lineHeight(24)
        .width('100%')
        .padding({ top: 4 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 分段导航的自定义 tabBar。
   *
   * 默认 tabBar 传字符串会渲染成系统样式的蓝色下划线标签，与全站的
   * 宋体 + 细线 + 石青完全不是一套语言。这里自绘：宋体标签 + 选中时
   * 一条 16px 短下划线，与底部 Tab 栏同一套规则。
   */
  @Builder
  sectionTab(index: number, label: string) {
    Column({ space: 5 }) {
      Text(label)
        .fontSize(12)
        .fontFamily(this.activeIndex === index ? FontFamily.serifBold : FontFamily.serif)
        .fontColor(this.activeIndex === index ? AppColor.primary : AppColor.textTertiary)
        .letterSpacing(1)
      Row()
        .width(this.activeIndex === index ? 16 : 0)
        .height(1.5)
        .backgroundColor(AppColor.primary)
    }
    .justifyContent(FlexAlign.Center)
    .padding({ left: 6, right: 6 })
  }

  /** 工具条按钮：在光标处插入一段 Markdown 语法 */
  @Builder
  toolChip(label: string, prefix: string, suffix: string) {
    Text(label)
      .fontSize(AppFont.caption)
      .fontFamily(FontFamily.serif)
      .fontColor(AppColor.primary)
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .backgroundColor(AppColor.background)
      .borderRadius(14)
      .borderWidth(1)
      .borderColor(AppColor.hairlineWarm)
      .margin({ right: 8 })
      .onClick(() => {
        this.insertMarkdown(prefix, suffix)
      })
  }

  /**
   * 笔记编辑面板。
   *
   * 用 bindSheet 而不是自己搭遮罩：半屏弹层的遮罩、拖拽、下滑关闭、
   * 软键盘避让都由系统处理，自己写反而容易在键盘弹出时把输入框顶没了。
   */
  @Builder
  noteEditor() {
    Column({ space: 12 }) {
      // 工具条：横向可滚，窄屏放不下五个胶囊
      Scroll() {
        Row() {
          this.toolChip('标题', '\n## ', '')
          this.toolChip('粗体', '**', '**')
          this.toolChip('列表', '\n- ', '')
          this.toolChip('引用', '\n> ', '')
          this.toolChip('代码', '`', '`')
        }
      }
      .width('100%')
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .align(Alignment.Start)

      TextArea({
        text: this.noteDraft,
        placeholder: '记下你的观察、疑问或出处。支持 Markdown：#、**粗体**、- 列表。',
        controller: this.taController,
      })
        .fontSize(AppFont.body)
        .fontFamily(FontFamily.serif)
        .placeholderColor(AppColor.textTertiary)
        .fontColor(AppColor.textPrimary)
        .backgroundColor(AppColor.background)
        .borderRadius(12)
        .borderWidth(1)
        .borderColor(AppColor.hairlineWarm)
        .lineHeight(24)
        .width('100%')
        .layoutWeight(1)
        .onChange((value: string) => {
          this.noteDraft = value
        })
        .onTextSelectionChange((start: number, end: number) => {
          this.caret = end
        })

      Row({ space: 10 }) {
        Text(`${this.noteDraft.length} 字`)
          .fontSize(11)
          .fontColor(AppColor.textTertiary)
          .layoutWeight(1)

        Text('取消')
          .fontSize(AppFont.caption)
          .fontFamily(FontFamily.serif)
          .fontColor(AppColor.textSecondary)
          .padding({ left: 18, right: 18, top: 9, bottom: 9 })
          .borderRadius(20)
          .borderWidth(1)
          .borderColor(AppColor.hairlineWarm)
          .onClick(() => {
            this.editing = false
          })

        Button(this.saving ? '保存中' : '保存')
          .fontSize(AppFont.caption)
          .fontFamily(FontFamily.serif)
          .fontColor(AppColor.surface)
          .backgroundColor(this.noteDraft.trim().length > 0 && !this.saving ? AppColor.primary : AppColor.textTertiary)
          .borderRadius(20)
          .height(38)
          .onClick(() => {
            this.submitNote()
          })
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding, bottom: AppSize.pagePadding })
    .justifyContent(FlexAlign.Start)
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        Text('返回')
          .fontSize(AppFont.body)
          .fontColor(AppColor.primary)
          .onClick(() => {
            router.back()
          })
        Text(this.item !== undefined ? this.item.name : '档案详情')
          .fontSize(20)
          .fontFamily(FontFamily.serifBold)
          .fontColor(AppColor.textPrimary)
          .letterSpacing(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding, top: 12, bottom: 12 })

      if (this.loading) {
        Column() {
          Text('加载中…')
            .fontSize(AppFont.body)
            .fontColor(AppColor.textSecondary)
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.item === undefined) {
        Column() {
          Text(this.error.length > 0 ? this.error : '未找到档案')
            .fontSize(AppFont.body)
            .fontColor(AppColor.danger)
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column({ space: AppSize.cardGap }) {
            this.header(this.item)

            this.personalCard()

            Tabs({ barPosition: BarPosition.Start, index: this.activeIndex }) {
              TabContent() {
                // Tabs 高度固定 560vp，内容超出会被裁掉且无法滚动 ——
                // 「考古发现」的出土文物条目就卡在这里。每个页签各自可滚。
                Scroll() {
                  Column() {
                    this.introSection(this.item)
                  }
                  .width('100%')
                  .alignItems(HorizontalAlign.Start)
                }
                .width('100%')
                .height('100%')
                .align(Alignment.TopStart)
                .scrollBar(BarState.Off)
                .edgeEffect(EdgeEffect.None)
              }
              .tabBar(this.sectionTab(0, SECTION_LABELS[0].label))

              TabContent() {
                // Tabs 高度固定 560vp，内容超出会被裁掉且无法滚动 ——
                // 「考古发现」的出土文物条目就卡在这里。每个页签各自可滚。
                Scroll() {
                  Column() {
                    this.archaeologySection(this.item)
                  }
                  .width('100%')
                  .alignItems(HorizontalAlign.Start)
                }
                .width('100%')
                .height('100%')
                .align(Alignment.TopStart)
                .scrollBar(BarState.Off)
                .edgeEffect(EdgeEffect.None)
              }
              .tabBar(this.sectionTab(1, SECTION_LABELS[1].label))

              TabContent() {
                // Tabs 高度固定 560vp，内容超出会被裁掉且无法滚动 ——
                // 「考古发现」的出土文物条目就卡在这里。每个页签各自可滚。
                Scroll() {
                  Column() {
                    this.eventsSection(this.item)
                  }
                  .width('100%')
                  .alignItems(HorizontalAlign.Start)
                }
                .width('100%')
                .height('100%')
                .align(Alignment.TopStart)
                .scrollBar(BarState.Off)
                .edgeEffect(EdgeEffect.None)
              }
              .tabBar(this.sectionTab(2, SECTION_LABELS[2].label))

              TabContent() {
                // Tabs 高度固定 560vp，内容超出会被裁掉且无法滚动 ——
                // 「考古发现」的出土文物条目就卡在这里。每个页签各自可滚。
                Scroll() {
                  Column() {
                    this.poemsSection(this.item)
                  }
                  .width('100%')
                  .alignItems(HorizontalAlign.Start)
                }
                .width('100%')
                .height('100%')
                .align(Alignment.TopStart)
                .scrollBar(BarState.Off)
                .edgeEffect(EdgeEffect.None)
              }
              .tabBar(this.sectionTab(3, SECTION_LABELS[3].label))

              TabContent() {
                // Tabs 高度固定 560vp，内容超出会被裁掉且无法滚动 ——
                // 「考古发现」的出土文物条目就卡在这里。每个页签各自可滚。
                Scroll() {
                  Column() {
                    this.travelSection(this.item)
                  }
                  .width('100%')
                  .alignItems(HorizontalAlign.Start)
                }
                .width('100%')
                .height('100%')
                .align(Alignment.TopStart)
                .scrollBar(BarState.Off)
                .edgeEffect(EdgeEffect.None)
              }
              .tabBar(this.sectionTab(4, SECTION_LABELS[4].label))

              TabContent() {
                // Tabs 高度固定 560vp，内容超出会被裁掉且无法滚动 ——
                // 「考古发现」的出土文物条目就卡在这里。每个页签各自可滚。
                Scroll() {
                  Column() {
                    this.graphSection()
                  }
                  .width('100%')
                  .alignItems(HorizontalAlign.Start)
                }
                .width('100%')
                .height('100%')
                .align(Alignment.TopStart)
                .scrollBar(BarState.Off)
                .edgeEffect(EdgeEffect.None)
              }
              .tabBar(this.sectionTab(5, SECTION_LABELS[5].label))
            }
            .barMode(BarMode.Scrollable)
            .barHeight(46)
            .barBackgroundColor(AppColor.background)
            .divider({ strokeWidth: 0 })
            .height(560)
            .onChange((index: number) => {
              this.activeIndex = index
            })
          }
          .width('100%')
          .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding, bottom: 24 })
          .alignItems(HorizontalAlign.Start)
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppColor.background)
    .backgroundImage($rawfile('img/paper.webp'))
    .backgroundImageSize(ImageSize.Cover)
    .bindSheet($$this.editing, this.noteEditor(), {
      height: 520,
      // 上滑可展开到接近全屏：长笔记需要更大的书写区
      detents: [520, SheetSize.LARGE],
      preferType: SheetType.BOTTOM,
      dragBar: true,
      title: {
        title: '写笔记',
        subtitle: this.item !== undefined ? this.item.name : '',
      },
      // 点遮罩关闭时同步状态，否则 editing 仍为 true，第二次点入口没反应
      onDisappear: () => {
        this.editing = false
      },
    })
  }
}

/** 以下三个接口对应 payload 中的嵌套结构，用于 ForEach 的元素类型标注 */

interface ImagePayload {
  readonly url: string
  readonly caption: string
  readonly credit: string
  readonly license: string
}

interface ArtifactPayload {
  readonly id: string
  readonly name: string
  readonly desc: string
  readonly museum?: string
}

interface EventPayload {
  readonly year: string
  readonly title: string
  readonly desc: string
}

interface PoemPayload {
  readonly title: string
  readonly author: string
  readonly dynasty: string
  readonly content: string
  readonly note?: string
}
