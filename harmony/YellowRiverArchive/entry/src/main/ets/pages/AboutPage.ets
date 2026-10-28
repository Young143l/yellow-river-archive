import { router } from '@kit.ArkUI'

import { AppColor, AppFont, AppSize } from '../constants/Theme'

interface AboutSection {
  readonly title: string
  readonly body: string
}

/**
 * 关于页：数据来源、版权声明、AI 使用说明。
 *
 * 这一页不是摆设 —— 参赛作品涉及大量第三方史料与图片，
 * 把「数据从哪来、授权到什么程度、哪些是 AI 生成的」写在明处，
 * 既是学术规范，也是评审关注点。含糊其辞反而是减分项。
 */
const SECTIONS: AboutSection[] = [
  {
    title: '这是什么',
    body:
      '黄河图志是一部黄河文化的分布式数字档案。它把河南段的重要遗址、文物与时代脉络' +
      '整理成可离线浏览、可语义检索、可追问、也能随身带走的知识档案。\n\n' +
      '所有正文与图片都预置在设备本地，断网时完整可用；联网时额外获得语义检索与 AI 问答。',
  },
  {
    title: '数据来源',
    body:
      '正文内容依据各地文物局、博物馆与考古发掘简报的公开资料整理，每个条目在详情页' +
      '标注了来源编号与原始出处。\n\n' +
      '图片来源以维基共享资源（Wikimedia Commons）的开放授权图片为主，逐张登记' +
      '作者、授权协议与原始链接，授权信息随条目一同展示。\n\n' +
      '史料原文与图片版权归原作者与收藏机构所有，本项目仅作教学与学术展示用途。',
  },
  {
    title: '关于 AI',
    body:
      'AI 用于两处：一是辅助整理正文初稿，二是回答提问时归纳检索到的原文。\n\n' +
      '两处都有约束：整理初稿时只允许使用登记在册的来源材料，不确定的内容标为待核实；' +
      '回答提问时只依据检索到的档案原文，并逐条标注引用出处，不凭空生成史实。\n\n' +
      '每个 AI 生成的回答下方都能看到它引用了哪几条资料，可以自行核对。',
  },
  {
    title: '你的数据',
    body:
      '收藏、笔记、标签、阅读进度只属于你。它们默认存在本机；开启同步后会在你自己的' +
      '设备之间流转，用于多端协同。\n\n' +
      '服务端只保存这些个人记录，不保存任何图片。你可以随时导出全部个人数据为备份文件，' +
      '也可以一键清空。',
  },
  {
    title: '技术构成',
    body:
      '客户端：HarmonyOS ArkTS / ArkUI，本地 SQLite 存储与全文检索。\n' +
      '服务端：TypeScript，混合检索（BM25 + 向量）与检索增强问答。\n' +
      '分布式：多端同步采用最后写入优先的冲突策略，支持备份与恢复。',
  },
]

@Entry
@Component
struct AboutPage {
  build() {
    Column() {
      Row() {
        Text('关于')
          .fontSize(AppFont.title)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
          .layoutWeight(1)
        Text('返回')
          .fontSize(AppFont.caption)
          .fontColor(AppColor.primary)
          .onClick(() => {
            router.back()
          })
      }
      .width('100%')
      .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding, top: 16, bottom: 12 })

      Scroll() {
        Column({ space: 20 }) {
          ForEach(
            SECTIONS,
            (section: AboutSection) => {
              Column({ space: 6 }) {
                Text(section.title)
                  .fontSize(AppFont.body)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(AppColor.primary)
                  .width('100%')
                Text(section.body)
                  .fontSize(AppFont.caption)
                  .fontColor(AppColor.textSecondary)
                  .lineHeight(22)
                  .width('100%')
              }
              .width('100%')
            },
            (section: AboutSection) => section.title
          )

          Column({ space: 4 }) {
            Divider()
              .color(AppColor.divider)
              .margin({ bottom: 12 })
            Text('黄河图志 · 1.0.0')
              .fontSize(11)
              .fontColor(AppColor.textTertiary)
              .width('100%')
            Text('2026 第三届河南省高等学校信息技术应用创新大赛')
              .fontSize(11)
              .fontColor(AppColor.textTertiary)
              .width('100%')
          }
          .width('100%')
          .margin({ bottom: 24 })
        }
        .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppColor.background)
  }
}
