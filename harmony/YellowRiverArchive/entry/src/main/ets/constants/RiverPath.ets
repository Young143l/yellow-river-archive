/**
 * 黄河河南段示意折线 + 沿线城市锚点。
 *
 * **这不是测绘数据。** 坐标简化到 0.1 度量级，只用于在首页画一条能看懂的
 * 河道示意，让遗址圆点落在符合真实地理关系的位置上。
 * 参赛作品涉及地理数据，来源与精度必须交代清楚，所以写在这里而不是藏在代码里。
 *
 * 取点依据：河道沿线各县市的公开地理位置，自西向东依次是
 * 三门峡 → 渑池 → 新安 → 孟津 → 巩义 → 荥阳桃花峪 → 郑州 → 中牟 →
 * 开封 → 封丘 → 长垣 → 濮阳 → 台前，与黄河在河南的实际走向一致。
 */

/** 一个地理坐标点 */
export class GeoPoint2 {
  readonly lat: number
  readonly lng: number

  constructor(lat: number, lng: number) {
    this.lat = lat
    this.lng = lng
  }
}

/**
 * 黄河主河道，自西向东。
 *
 * 首尾各多给一个点，让河道从画布两侧「流出去」——
 * 河流在真实地图上不会在边界处断头，视觉上要能延伸出画面。
 */
export const RIVER_HENAN: GeoPoint2[] = [
  new GeoPoint2(34.58, 110.72), // 省界以西，画外
  new GeoPoint2(34.72, 111.20), // 三门峡
  new GeoPoint2(34.78, 111.48), // 陕州
  new GeoPoint2(34.86, 111.75), // 渑池北
  new GeoPoint2(34.85, 112.13), // 新安
  new GeoPoint2(34.84, 112.44), // 孟津
  new GeoPoint2(34.83, 113.02), // 巩义北
  new GeoPoint2(34.90, 113.27), // 荥阳桃花峪
  new GeoPoint2(34.90, 113.65), // 郑州北
  new GeoPoint2(34.88, 113.98), // 中牟
  new GeoPoint2(34.85, 114.35), // 开封北
  new GeoPoint2(34.98, 114.42), // 封丘
  new GeoPoint2(35.20, 114.68), // 长垣
  new GeoPoint2(35.76, 115.03), // 濮阳
  new GeoPoint2(35.97, 115.87), // 台前
  new GeoPoint2(36.10, 116.30), // 省界以东，画外
]

/** 沿线城市标注 */
export class CityAnchor {
  readonly name: string
  readonly lat: number
  readonly lng: number

  constructor(name: string, lat: number, lng: number) {
    this.name = name
    this.lat = lat
    this.lng = lng
  }
}

export const RIVER_CITIES: CityAnchor[] = [
  new CityAnchor('三门峡', 34.78, 111.20),
  new CityAnchor('洛阳', 34.84, 112.44),
  new CityAnchor('郑州', 34.90, 113.65),
  new CityAnchor('开封', 34.85, 114.35),
  new CityAnchor('濮阳', 35.76, 115.03),
]

/**
 * 投影参数。
 *
 * 经度跨度约 3.2 度、纬度跨度仅约 1.0 度，真按等比画会被压成一条薄带。
 * 加上纬度越高经度对应的实际距离越短（cos 34.7° ≈ 0.82），
 * 真实长宽比约 2.6:1，而竖屏画布是 0.6:1，两者差得太远。
 *
 * 所以这里**故意不等比**：纵向放大到 3 倍左右，让南北差异可辨。
 * 这是示意图的常规做法（地铁线路图同理），不是错误。
 */
export class MapProjection {
  readonly minLat: number
  readonly maxLat: number
  readonly minLng: number
  readonly maxLng: number
  readonly left: number
  readonly top: number
  readonly width: number
  readonly height: number

  constructor(
    minLat: number,
    maxLat: number,
    minLng: number,
    maxLng: number,
    left: number,
    top: number,
    width: number,
    height: number
  ) {
    this.minLat = minLat
    this.maxLat = maxLat
    this.minLng = minLng
    this.maxLng = maxLng
    this.left = left
    this.top = top
    this.width = width
    this.height = height
  }

  /** 经度 → 画布 x */
  x(lng: number): number {
    const span: number = Math.max(0.0001, this.maxLng - this.minLng)
    return this.left + ((lng - this.minLng) / span) * this.width
  }

  /** 纬度 → 画布 y（纬度越高越靠上） */
  y(lat: number): number {
    const span: number = Math.max(0.0001, this.maxLat - this.minLat)
    return this.top + ((this.maxLat - lat) / span) * this.height
  }
}

/**
 * 按遗址分布构造投影。
 *
 * 边界只取**遗址**的范围而非整条河：五个遗址集中在经度 111.8-115.0、
 * 纬度 34.7-35.7 之间，若按整条河取边界，遗址会全挤在画面西侧一小块。
 * 河道超出边界的部分自然画到画外，视觉上像是从画面两侧流出。
 */
export function projectionFor(
  minLat: number,
  maxLat: number,
  minLng: number,
  maxLng: number,
  left: number,
  top: number,
  width: number,
  height: number,
  padRatio: number = 0.10
): MapProjection {
  const latSpan: number = Math.max(0.01, maxLat - minLat)
  const lngSpan: number = Math.max(0.01, maxLng - minLng)
  const latPad: number = latSpan * padRatio
  const lngPad: number = lngSpan * padRatio
  return new MapProjection(
    minLat - latPad,
    maxLat + latPad,
    minLng - lngPad,
    maxLng + lngPad,
    left,
    top,
    width,
    height
  )
}

// ---------------------------------------------------------------- 曲线

/** 归一化坐标点（0-1，相对画布宽高） */
export class CurvePoint {
  readonly x: number
  readonly y: number

  constructor(x: number, y: number) {
    this.x = x
    this.y = y
  }
}

/**
 * 黄河在画面上的走向（归一化控制点）。
 *
 * **这一版不再用原始经纬度做线性投影。** 原因是实测下来投影结果很难看：
 * 经度 111.7-114.4 这 2.7 度横跨了五个遗址中的四个，剩下一度全给了濮阳那段
 * 折向东北的河道，结果五个点全挤在左下角，右上角大片留白，构图严重失衡。
 * 而且折线拐角生硬，完全不像水。
 *
 * 改为「手工控制点 + 样条平滑」：形状可控、像河，遗址按顺序沿线排布，
 * 构图天然均衡。代价是放弃了精确地理投影 —— 这与「大致流向的示意图」的
 * 定位一致，且在页面上注明了非测绘。
 */
export const RIVER_CONTROL: CurvePoint[] = [
  new CurvePoint(-0.04, 0.70),
  new CurvePoint(0.14, 0.66),
  new CurvePoint(0.32, 0.68),
  new CurvePoint(0.48, 0.62),
  new CurvePoint(0.62, 0.56),
  new CurvePoint(0.74, 0.44),
  new CurvePoint(0.86, 0.30),
  new CurvePoint(1.04, 0.16),
]

/**
 * Catmull-Rom 样条：把控制点采样成密集折线。
 *
 * 为什么要自己采样而不是直接用贝塞尔：**需要按弧长定位遗址**。
 * 只有拿到密集采样点与累积弧长，才能回答「沿河 30% 处是哪个位置」，
 * 这样遗址之间的间距才可控，而不是在拐弯处挤成一坨。
 */
export class RiverCurve {
  readonly samples: CurvePoint[] = []
  private readonly cumulative: number[] = []
  private totalLength: number = 0

  constructor(control: CurvePoint[], segmentsPerSpan: number) {
    const n: number = control.length
    for (let i = 0; i < n - 1; i += 1) {
      const p0: CurvePoint = control[Math.max(0, i - 1)]
      const p1: CurvePoint = control[i]
      const p2: CurvePoint = control[i + 1]
      const p3: CurvePoint = control[Math.min(n - 1, i + 2)]
      for (let s = 0; s < segmentsPerSpan; s += 1) {
        const t: number = s / segmentsPerSpan
        this.samples.push(new CurvePoint(
          RiverCurve.cr(p0.x, p1.x, p2.x, p3.x, t),
          RiverCurve.cr(p0.y, p1.y, p2.y, p3.y, t)
        ))
      }
    }
    this.samples.push(control[n - 1])

    // 累积弧长
    let acc: number = 0
    this.cumulative.push(0)
    for (let i = 1; i < this.samples.length; i += 1) {
      const dx: number = this.samples[i].x - this.samples[i - 1].x
      const dy: number = this.samples[i].y - this.samples[i - 1].y
      acc += Math.sqrt(dx * dx + dy * dy)
      this.cumulative.push(acc)
    }
    this.totalLength = acc
  }

  private static cr(a: number, b: number, c: number, d: number, t: number): number {
    const t2: number = t * t
    const t3: number = t2 * t
    return 0.5 * (
      2 * b +
      (-a + c) * t +
      (2 * a - 5 * b + 4 * c - d) * t2 +
      (-a + 3 * b - 3 * c + d) * t3
    )
  }

  /** 取弧长比例 frac（0-1）处的点 */
  pointAt(frac: number): CurvePoint {
    if (this.samples.length === 0) {
      return new CurvePoint(0, 0)
    }
    const target: number = Math.max(0, Math.min(1, frac)) * this.totalLength
    for (let i = 1; i < this.cumulative.length; i += 1) {
      if (this.cumulative[i] >= target) {
        const span: number = this.cumulative[i] - this.cumulative[i - 1]
        const k: number = span > 0 ? (target - this.cumulative[i - 1]) / span : 0
        const a: CurvePoint = this.samples[i - 1]
        const b: CurvePoint = this.samples[i]
        return new CurvePoint(a.x + (b.x - a.x) * k, a.y + (b.y - a.y) * k)
      }
    }
    return this.samples[this.samples.length - 1]
  }
}

/**
 * 各遗址在河道上的位置（弧长比例）。
 *
 * 顺序严格按经度自西向东：仰韶村 → 二里头 → 巩义窑址 → 开宝寺塔 → 西水坡。
 * 间距经过调整：二里头与巩义窑址经度只差 0.23 度，按真实比例会几乎重叠，
 * 这里拉开到 0.14 以保证可读。**顺序是真实的，间距是排版用的。**
 */
export class SiteOnRiver {
  readonly itemId: string
  readonly frac: number

  constructor(itemId: string, frac: number) {
    this.itemId = itemId
    this.frac = frac
  }
}

export const SITE_RIVER_POSITIONS: SiteOnRiver[] = [
  new SiteOnRiver('sms-yangshao', 0.10),
  new SiteOnRiver('ly-erlitou', 0.33),
  new SiteOnRiver('zz-gongyi-yao', 0.47),
  new SiteOnRiver('kf-kaibaosi-ta', 0.72),
  new SiteOnRiver('py-xishuipo', 0.90),
]
