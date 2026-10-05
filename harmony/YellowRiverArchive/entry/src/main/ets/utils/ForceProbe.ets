/**
 * D0V-3 探针：Canvas 力导向布局的性能测定。
 *
 * 用真实的力导向算法（斥力 + 弹簧 + 向心 + 阻尼）跑若干帧，同时绘制连边与节点，
 * 测出「每帧 CPU 耗时」。若单帧耗时明显低于 16.6ms，则 60fps 有保障。
 *
 * 结论直接影响：图谱页的节点上限、是否需要网格桶近似、是否要降级为静态图。
 */

/** 布局节点 */
export class ForceNode {
  x: number
  y: number
  vx: number
  vy: number

  constructor(x: number, y: number) {
    this.x = x
    this.y = y
    this.vx = 0
    this.vy = 0
  }
}

/** 连边（用节点下标表示） */
export interface ForceEdge {
  readonly a: number
  readonly b: number
}

/** 一次性构建出的图 */
export interface ForceGraph {
  readonly nodes: ForceNode[]
  readonly edges: ForceEdge[]
}

/** 性能报告 */
export class ForceReport {
  readonly nodeCount: number
  readonly edgeCount: number
  readonly frames: number
  readonly totalMs: number
  readonly msPerFrame: number

  constructor(nodeCount: number, edgeCount: number, frames: number, totalMs: number) {
    this.nodeCount = nodeCount
    this.edgeCount = edgeCount
    this.frames = frames
    this.totalMs = totalMs
    this.msPerFrame = Math.round((totalMs / frames) * 100) / 100
  }

  /** 单帧耗时低于 16.6ms 即认为可稳定 60fps */
  get smooth(): boolean {
    return this.msPerFrame < 16.6
  }
}

/** 线性同余伪随机，保证每次运行结果可复现 */
class Rng {
  private seed: number

  constructor(seed: number) {
    this.seed = seed
  }

  next(): number {
    this.seed = (this.seed * 1103515245 + 12345) % 2147483648
    return this.seed / 2147483648
  }
}

export class ForceProbe {
  /** 构建一张"星形 + 随机"混合图，比纯随机更接近真实知识图谱的度分布 */
  static buildGraph(nodeCount: number, edgeCount: number, width: number, height: number): ForceGraph {
    const rng: Rng = new Rng(20261005)
    const nodes: ForceNode[] = []
    for (let i = 0; i < nodeCount; i++) {
      nodes.push(new ForceNode(rng.next() * width, rng.next() * height))
    }

    const edges: ForceEdge[] = []
    // 少量枢纽节点承载大部分连边，模拟"遗址—时代—城市"这类中心结构
    const hubCount: number = Math.max(1, Math.round(nodeCount / 20))
    for (let i = 0; i < edgeCount; i++) {
      const a: number = i % hubCount
      const b: number = hubCount + Math.floor(rng.next() * (nodeCount - hubCount))
      if (a !== b) {
        edges.push({ a: a, b: b })
      }
    }
    return { nodes: nodes, edges: edges }
  }

  /** 推进一帧物理模拟 */
  static step(graph: ForceGraph, width: number, height: number): void {
    const nodes: ForceNode[] = graph.nodes
    const count: number = nodes.length
    const centerX: number = width / 2
    const centerY: number = height / 2
    const repulsion: number = 900
    const minDistSq: number = 64

    // 斥力（全对计算，O(n²)）
    for (let i = 0; i < count; i++) {
      const ni: ForceNode = nodes[i]
      for (let j = i + 1; j < count; j++) {
        const nj: ForceNode = nodes[j]
        let dx: number = ni.x - nj.x
        let dy: number = ni.y - nj.y
        let distSq: number = dx * dx + dy * dy
        if (distSq < minDistSq) {
          distSq = minDistSq
          dx = dx + 0.5
          dy = dy + 0.5
        }
        const factor: number = repulsion / (distSq * Math.sqrt(distSq))
        const fx: number = dx * factor
        const fy: number = dy * factor
        ni.vx += fx
        ni.vy += fy
        nj.vx -= fx
        nj.vy -= fy
      }
    }

    // 弹簧
    const springLength: number = 42
    const springK: number = 0.02
    for (const e of graph.edges) {
      const na: ForceNode = nodes[e.a]
      const nb: ForceNode = nodes[e.b]
      const dx: number = nb.x - na.x
      const dy: number = nb.y - na.y
      const dist: number = Math.sqrt(dx * dx + dy * dy) + 0.01
      const force: number = (dist - springLength) * springK
      const fx: number = (dx / dist) * force
      const fy: number = (dy / dist) * force
      na.vx += fx
      na.vy += fy
      nb.vx -= fx
      nb.vy -= fy
    }

    // 向心力 + 阻尼 + 位置更新
    const damping: number = 0.82
    const centering: number = 0.002
    for (const n of nodes) {
      n.vx += (centerX - n.x) * centering
      n.vy += (centerY - n.y) * centering
      n.vx *= damping
      n.vy *= damping
      n.x += n.vx
      n.y += n.vy
      if (n.x < 4) {
        n.x = 4
      }
      if (n.x > width - 4) {
        n.x = width - 4
      }
      if (n.y < 4) {
        n.y = 4
      }
      if (n.y > height - 4) {
        n.y = height - 4
      }
    }
  }

  /** 绘制一帧 */
  static draw(
    ctx: CanvasRenderingContext2D,
    graph: ForceGraph,
    width: number,
    height: number
  ): void {
    ctx.clearRect(0, 0, width, height)

    // 连边
    ctx.strokeStyle = '#D8CDBE'
    ctx.lineWidth = 0.5
    ctx.beginPath()
    for (const e of graph.edges) {
      const a: ForceNode = graph.nodes[e.a]
      const b: ForceNode = graph.nodes[e.b]
      ctx.moveTo(a.x, a.y)
      ctx.lineTo(b.x, b.y)
    }
    ctx.stroke()

    // 节点
    ctx.fillStyle = '#8C3B1E'
    for (const n of graph.nodes) {
      ctx.beginPath()
      ctx.arc(n.x, n.y, 3, 0, Math.PI * 2)
      ctx.fill()
    }
  }

  /** 跑指定帧数并返回性能报告 */
  static run(
    ctx: CanvasRenderingContext2D,
    width: number,
    height: number,
    nodeCount: number,
    edgeCount: number,
    frames: number
  ): ForceReport {
    const graph: ForceGraph = ForceProbe.buildGraph(nodeCount, edgeCount, width, height)

    // 先热跑 5 帧，避开首次绘制的初始化开销
    for (let i = 0; i < 5; i++) {
      ForceProbe.step(graph, width, height)
      ForceProbe.draw(ctx, graph, width, height)
    }

    const started: number = Date.now()
    for (let i = 0; i < frames; i++) {
      ForceProbe.step(graph, width, height)
      ForceProbe.draw(ctx, graph, width, height)
    }
    const totalMs: number = Date.now() - started

    return new ForceReport(nodeCount, edgeCount, frames, totalMs)
  }
}
