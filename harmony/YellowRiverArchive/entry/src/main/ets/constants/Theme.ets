/**
 * 端侧 UI 主题常量。
 * 只放样式值；业务常量见 ../shared/constants.ets（由 tools/gen 生成）。
 */

export class AppColor {
  /** 主色：黄河赭石 */
  static readonly primary: string = '#8C3B1E'
  static readonly primaryLight: string = '#B25E3A'
  /** 页面底色：宣纸米 */
  static readonly background: string = '#F7F3EC'
  static readonly surface: string = '#FFFFFF'
  static readonly textPrimary: string = '#1F1B16'
  static readonly textSecondary: string = '#6B6259'
  static readonly textTertiary: string = '#9A9086'
  static readonly divider: string = '#E6DED2'
  static readonly tabActive: string = '#8C3B1E'
  static readonly tabInactive: string = '#9A9086'
}

export class AppSize {
  static readonly pagePadding: number = 16
  static readonly cardRadius: number = 12
  static readonly cardGap: number = 12
  static readonly tabBarHeight: number = 56
}

export class AppFont {
  static readonly title: number = 22
  static readonly heading: number = 18
  static readonly body: number = 15
  static readonly caption: number = 13
  static readonly tab: number = 12
}
