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
