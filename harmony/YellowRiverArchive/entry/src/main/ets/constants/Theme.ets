/**
 * 端侧 UI 主题常量。
 * 只放样式值；业务常量见 ../shared/constants.ets（由 tools/gen 生成）。
 */

/**
 * 配色：青绿山水。
 *
 * 全站配色取自首页那条黄河 —— 石青画水、赭石画泥沙、石绿画滩地植被、
 * 朱砂做印记。四个矿物色构成一套完整的中式色谱，各页面都从这里取值，
 * 不再各自硬编码色值。
 *
 * 分工是刻意的：
 *   - **石青（primary）** 承担"可交互"：选中、链接、按钮、进度
 *   - **朱砂（seal）** 只用于印记与段落标题，是"郑重"的信号，不承担功能
 *   - **赭石（earth）** 用于次要强调与地理信息
 *   - **石绿（vegetation）** 极少用，只在需要"生机"的地方点缀
 * 若让朱砂去做按钮，印与按钮同色，两套语义就混了。
 */
export class AppColor {
  /** 主色：石青（水）。承担一切可交互元素 */
  static readonly primary: string = '#3D7288'
  static readonly primaryLight: string = '#5A8FA4'
  /** 印记色：朱砂。只用于印章与段落标题 */
  static readonly seal: string = '#A2392B'
  /** 土色：赭石。次要强调、地理信息 */
  static readonly earth: string = '#A97544'
  /** 植被：石绿 */
  static readonly vegetation: string = '#5E8A6B'
  /** 提示/错误：朱砂加深。不与 seal 混用 —— 印章是装饰，这个承载语义 */
  static readonly danger: string = '#8E2F22'

  /** 页面底色：宣纸 */
  static readonly background: string = '#F2EDE0'
  /** 卡片/浮层底色：比纸略亮 */
  static readonly surface: string = '#FBF8F0'
  /** 墨：正文。带一点冷调，与石青呼应 */
  static readonly textPrimary: string = '#23303A'
  static readonly textSecondary: string = '#5A6B74'
  static readonly textTertiary: string = '#8D9AA1'
  static readonly divider: string = '#DED5C3'
  static readonly tabActive: string = '#3D7288'
  static readonly tabInactive: string = '#93A0A6'
}

export class AppSize {
  static readonly pagePadding: number = 16
  static readonly cardRadius: number = 12
  static readonly cardGap: number = 12
  static readonly tabBarHeight: number = 56
}

/**
 * 字体族。
 *
 * 思源宋体两档分开注册（见 EntryAbility）：SemiBold 的 name 表 family 与 Regular
 * 不同族，靠 fontWeight 切换会让 ArkUI 合成粗体 —— 中文合成粗体会糊。
 * 所以「要用粗体」的地方直接换 family，而不是调 fontWeight。
 */
export class FontFamily {
  static readonly serif: string = 'Serif'
  static readonly serifBold: string = 'SerifBold'
}

export class AppFont {
  static readonly title: number = 22
  static readonly heading: number = 18
  static readonly body: number = 15
  static readonly caption: number = 13
  static readonly tab: number = 12
}
