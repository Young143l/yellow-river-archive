/**
 * 地理计算。从 graph.ts 抽出，供图谱与关联推荐共用 ——
 * 两处都要判断「两条遗址隔多远」，各写一份迟早会漂移。
 */

const toRad = (d: number): number => (d * Math.PI) / 180

/** 两点间大圆距离（公里） */
export function distanceKm(lat1: number, lng1: number, lat2: number, lng2: number): number {
  const dLat: number = toRad(lat2 - lat1)
  const dLng: number = toRad(lng2 - lng1)
  const a: number =
    Math.sin(dLat / 2) * Math.sin(dLat / 2) +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) * Math.sin(dLng / 2)
  return 6371 * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))
}
