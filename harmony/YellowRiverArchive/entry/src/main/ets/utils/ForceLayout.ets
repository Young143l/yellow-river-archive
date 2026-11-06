/**
 * 力导向布局。
 *
 * 算法与 D0-V 验证过的版本一致：Fruchterman-Reingold 的经典三条力
 * （斥力 / 弹簧引力 / 向心力），加阻尼收敛。
 *
 * 性能取舍（依据 D0-V 实测）：**朴素 O(n²) 斥力在 200-300 节点内可用**
 * （200 节点 6.57ms/帧，约 152fps）。超过 500 节点需要网格桶近似 ——
 * 本项目的图谱规模是 57-500 节点，因此先不做，但把阈值写成常量便于后续替换。
 */

/** 超过此节点数启用网格桶近似（斥力只算邻近 3x3 格，远于截断半径的节点对不计） */
export const GRID_BUCKET_THRESHOLD: number = 500

/** 布局中的节点：位置、速度与视觉属性 */
export class SimNode {
  readonly id: string
  readonly name: string
  readonly type: string
  /** 归一化权重（0-1），决定绘制半径 */
  readonly weight: number
  x: number = 0
  y: number = 0
  vx: number = 0
  vy: number = 0
  /** 是否被拖动固定 */
  fixed: boolean = false
  /**
   * 所属簇（通常是它归属的遗址 id）。
   *
   * 这一项存在的理由：**纯力导向画出来的 57 节点图是一团毛线** ——
   * 节点随机分布、边四处乱穿，放大也读不出结构。
   * 而数据本身有明确的簇（5 个遗址各带自己的文物与时代），
   * 让同簇节点互相靠近、异簇互相排斥，图才会呈现「5 个团」而不是「一锅粥」。
   */
  cluster: string = ''
  /** 聚焦模式下不参与绘制（只留焦点与其一跳邻居） */
  hidden: boolean = false

  constructor(id: string, name: string, type: string, weight: number) {
    this.id = id
    this.name = name
    this.type = type
    this.weight = weight
  }

  /** 半径：既要有区分度，又不能小到看不见 */
  radius(): number {
    return 5 + this.weight * 12
  }
}

/** 簇心坐标 */
export class ClusterCenter {
  readonly x: number
  readonly y: number

  constructor(x: number, y: number) {
    this.x = x
    this.y = y
  }
}

/** 布局中的边 */
export class SimEdge {
  readonly from: number
  readonly to: number
  readonly weight: number

  constructor(from: number, to: number, weight: number) {
    this.from = from
    this.to = to
    this.weight = weight
  }
}

export class ForceLayout {
  readonly nodes: SimNode[] = []
  readonly edges: SimEdge[] = []
  /** 簇心：种子阶段按簇数目均分在圆环上，之后固定不动 */
  readonly clusterCenters: Map<string, ClusterCenter> = new Map<string, ClusterCenter>()

  private readonly width: number
  private readonly height: number

  constructor(width: number, height: number) {
    this.width = width
    this.height = height
  }

  /**
   * 初始化位置。
   *
   * 用**黄金角螺旋**撒点而不是随机：随机撒点会让初始能量过高、
   * 布局抖动明显；螺旋分布既均匀又确定性，每次打开页面的初始形态一致。
   */
  seed(): void {
    const cx: number = this.width / 2
    const cy: number = this.height / 2

    // ---- 簇心均匀排在圆环上 ----
    const clusterIds: string[] = []
    for (const node of this.nodes) {
      if (!clusterIds.includes(node.cluster)) {
        clusterIds.push(node.cluster)
      }
    }
    clusterIds.sort()
    this.clusterCenters.clear()
    const ringR: number = Math.min(this.width, this.height) * 0.30
    clusterIds.forEach((cid: string, i: number) => {
      const theta: number = (Math.PI * 2 * i) / Math.max(1, clusterIds.length) - Math.PI / 2
      this.clusterCenters.set(cid, new ClusterCenter(cx + ringR * Math.cos(theta), cy + ringR * Math.sin(theta)))
    })

    // ---- 成员围绕各自簇心按黄金角螺旋撒点 ----
    const golden: number = Math.PI * (3 - Math.sqrt(5))
    const seenInCluster: Map<string, number> = new Map<string, number>()
    this.nodes.forEach((node) => {
      const k: number = seenInCluster.get(node.cluster) ?? 0
      seenInCluster.set(node.cluster, k + 1)
      const center: ClusterCenter | undefined = this.clusterCenters.get(node.cluster)
      const bx: number = center !== undefined ? center.x : cx
      const by: number = center !== undefined ? center.y : cy
      // 簇内规模决定展开半径，簇越大散得越开
      const spread: number = 26 * Math.sqrt(k + 0.5)
      const theta: number = golden * (k + 1)
      node.x = bx + spread * Math.cos(theta)
      node.y = by + spread * Math.sin(theta)
      node.vx = 0
      node.vy = 0
    })
  }

  /** 迭代一步 */
  step(): void {
    const n: number = this.nodes.length
    if (n === 0) {
      return
    }
    const cx: number = this.width / 2
    const cy: number = this.height / 2

    // 理想边长按「可用面积 / 节点数」定，而不是按画布宽度
    // 旧算法 width/sqrt(n)*0.9 在 390 宽、57 节点时被下限 46 卡住，
    // 结果是所有节点挤进一个直径不到 300px 的团里，标签全糊。
    // 面积法：每节点应占约 1/1.6² 的均分面积，再开方得间距
    const area: number = this.width * this.height
    const idealLength: number = Math.max(64, Math.min(200, Math.sqrt(area / n) * 1.55))
    const repulsion: number = idealLength * idealLength
    const damping: number = 0.82
    const centerPull: number = 0.012

    // ---- 斥力 ----
    // 节点数超阈值时用网格桶：斥力本就随距离平方衰减，远于 2 倍理想边长
    // 的节点对贡献可忽略。按截断半径分格，只扫自身与相邻 8 格。
    // 全量语料规模下约 700 节点，朴素 O(n²) 实测约 80ms/帧（12fps，动画不可用）；
    // 桶化后每节点只与常数个邻居交互，降到几毫秒级。
    const useBuckets: boolean = n > GRID_BUCKET_THRESHOLD
    const cutoff: number = idealLength * 2
    if (useBuckets) {
      const cell: number = Math.max(1, cutoff)
      const buckets: Map<string, number[]> = new Map<string, number[]>()
      for (let i = 0; i < n; i += 1) {
        const nd: SimNode = this.nodes[i]
        if (nd.hidden) {
          continue
        }
        const key: string = `${Math.floor(nd.x / cell)}_${Math.floor(nd.y / cell)}`
        const arr: number[] | undefined = buckets.get(key)
        if (arr !== undefined) {
          arr.push(i)
        } else {
          buckets.set(key, [i])
        }
      }
      for (let i = 0; i < n; i += 1) {
        const a: SimNode = this.nodes[i]
        if (a.hidden) {
          continue
        }
        const gx: number = Math.floor(a.x / cell)
        const gy: number = Math.floor(a.y / cell)
        for (let ox: number = -1; ox <= 1; ox += 1) {
          for (let oy: number = -1; oy <= 1; oy += 1) {
            const arr: number[] | undefined = buckets.get(`${gx + ox}_${gy + oy}`)
            if (arr === undefined) {
              continue
            }
            for (const j of arr) {
              if (j <= i) {
                continue
              }
              const b: SimNode = this.nodes[j]
              let dx: number = a.x - b.x
              let dy: number = a.y - b.y
              let dist2: number = dx * dx + dy * dy
              if (dist2 > cutoff * cutoff) {
                continue
              }
              if (dist2 < 0.01) {
                dx = (i % 7) - 3
                dy = (j % 5) - 2
                dist2 = dx * dx + dy * dy + 0.01
              }
              const dist: number = Math.sqrt(dist2)
              const force: number = repulsion / dist2
              const fx: number = (dx / dist) * force
              const fy: number = (dy / dist) * force
              a.vx += fx
              a.vy += fy
              b.vx -= fx
              b.vy -= fy
            }
          }
        }
      }
    } else {
      for (let i = 0; i < n; i += 1) {
        const a: SimNode = this.nodes[i]
        if (a.hidden) {
          continue
        }
        for (let j = i + 1; j < n; j += 1) {
          const b: SimNode = this.nodes[j]
          if (b.hidden) {
            continue
          }
          let dx: number = a.x - b.x
          let dy: number = a.y - b.y
          let dist2: number = dx * dx + dy * dy
          if (dist2 < 0.01) {
            // 完全重合时给一个确定性的微扰，避免除零后 NaN 扩散到整张图
            dx = (i % 7) - 3
            dy = (j % 5) - 2
            dist2 = dx * dx + dy * dy + 0.01
          }
          const dist: number = Math.sqrt(dist2)
          const force: number = repulsion / dist2
          const fx: number = (dx / dist) * force
          const fy: number = (dy / dist) * force
          a.vx += fx
          a.vy += fy
          b.vx -= fx
          b.vy -= fy
        }
      }
    }

    // ---- 弹簧引力（隐藏节点不参与） ----
    for (const edge of this.edges) {
      const a: SimNode = this.nodes[edge.from]
      const b: SimNode = this.nodes[edge.to]
      if (a === undefined || b === undefined || a.hidden || b.hidden) {
        continue
      }
      const dx: number = a.x - b.x
      const dy: number = a.y - b.y
      const dist: number = Math.max(0.01, Math.sqrt(dx * dx + dy * dy))
      // 权重越高，期望距离越短 —— 关联紧密的节点自然靠拢
      const target: number = idealLength * (1.6 - Math.min(0.6, edge.weight * 0.6))
      const force: number = (dist - target) * 0.04
      const fx: number = (dx / dist) * force
      const fy: number = (dy / dist) * force
      a.vx -= fx
      a.vy -= fy
      b.vx += fx
      b.vy += fy
    }

    // ---- 向心力 + 阻尼 + 边界收敛（隐藏节点冻结） ----
    for (const node of this.nodes) {
      if (node.hidden) {
        node.vx = 0
        node.vy = 0
        continue
      }
      if (node.fixed) {
        node.vx = 0
        node.vy = 0
        continue
      }
      node.vx += (cx - node.x) * centerPull
      node.vy += (cy - node.y) * centerPull

      // 簇凝聚力：把节点拉向自己簇的簇心。
      // 强度取 0.05 —— 明显强于向心力 0.012（否则簇会被整体拉塌），
      // 又远弱于簇内弹簧引力（否则簇内结构会被压成一个点）。
      // 有了这一项，簇才不会被簇间斥力推开、散成一锅粥。
      const center: ClusterCenter | undefined = this.clusterCenters.get(node.cluster)
      if (center !== undefined) {
        node.vx += (center.x - node.x) * 0.05
        node.vy += (center.y - node.y) * 0.05
      }
      node.vx *= damping
      node.vy *= damping
      node.x += node.vx
      node.y += node.vy

      const margin: number = 18
      if (node.x < margin) {
        node.x = margin
        node.vx = 0
      } else if (node.x > this.width - margin) {
        node.x = this.width - margin
        node.vx = 0
      }
      if (node.y < margin) {
        node.y = margin
        node.vy = 0
      } else if (node.y > this.height - margin) {
        node.y = this.height - margin
        node.vy = 0
      }
    }
  }

  /** 总动能（隐藏节点不计，否则冻结子图永远不收敛） */
  energy(): number {
    let sum: number = 0
    for (const node of this.nodes) {
      if (node.hidden) {
        continue
      }
      sum += node.vx * node.vx + node.vy * node.vy
    }
    return sum
  }

  /**
   * 径向种子：焦点居中固定，一跳邻居黄金角螺旋环绕。
   * 聚焦模式的专用初始化 —— 全图 seed() 会把邻居放到各自簇心去，
   * 聚焦子图看起来就散架了。
   */
  radialSeed(focusIndex: number): void {
    const cx: number = this.width / 2
    const cy: number = this.height / 2
    const focus: SimNode | undefined = this.nodes[focusIndex]
    if (focus === undefined) {
      return
    }
    focus.x = cx
    focus.y = cy
    focus.vx = 0
    focus.vy = 0
    focus.fixed = true

    const neighborSet: Set<number> = new Set<number>()
    for (const edge of this.edges) {
      if (edge.from === focusIndex) {
        neighborSet.add(edge.to)
      } else if (edge.to === focusIndex) {
        neighborSet.add(edge.from)
      }
    }
    const golden: number = Math.PI * (3 - Math.sqrt(5))
    let k: number = 0
    this.nodes.forEach((node: SimNode, i: number) => {
      node.vx = 0
      node.vy = 0
      if (i === focusIndex || !neighborSet.has(i)) {
        return
      }
      const spread: number = 84 + 30 * Math.sqrt(k + 0.5)
      const theta: number = golden * (k + 1)
      node.x = cx + spread * Math.cos(theta)
      node.y = cy + spread * Math.sin(theta)
      k += 1
    })
  }

  /** 命中测试：返回被点中的节点下标（-1 表示没点中） */
  /** 命中测试。threshold 是布局坐标下的容差半径，调用方按视图缩放换算 */
  hitTest(x: number, y: number, threshold: number): number {
    let best: number = -1
    let bestDist: number = threshold * threshold
    this.nodes.forEach((node, index) => {
      if (node.hidden) {
        return
      }
      const dx: number = node.x - x
      const dy: number = node.y - y
      const d2: number = dx * dx + dy * dy
      if (d2 < bestDist) {
        bestDist = d2
        best = index
      }
    })
    return best
  }
}
