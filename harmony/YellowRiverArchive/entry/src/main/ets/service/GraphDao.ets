/**
 * 图谱数据访问。
 *
 * 只从本地 RDB 读（离线优先）：图谱是离线资产，不该依赖网络。
 * 节点权重直接用构建期算好的 `rank`（归一化度数），端侧不再跑 PageRank ——
 * 端侧跑一遍要多几百毫秒，而构建期算一次就够全设备复用。
 */

import { common } from '@kit.AbilityKit'
import { relationalStore } from '@kit.ArkData'

import type { GraphEdge, GraphNode, GraphNodeType, GraphRelation } from '../shared'
import { Tables } from '../model/Schema'
import { DataImportService } from './DataImportService'

export class GraphDao {
  static async nodes(context: common.Context): Promise<GraphNode[]> {
    const store: relationalStore.RdbStore = await DataImportService.open(context)
    const rs: relationalStore.ResultSet = await store.querySql(
      `SELECT id, type, name, aliases, rank FROM ${Tables.GRAPH_NODES}`
    )
    const list: GraphNode[] = []
    while (rs.goToNextRow()) {
      const aliasesText: string = rs.getString(rs.getColumnIndex('aliases'))
      list.push({
        id: rs.getString(rs.getColumnIndex('id')),
        type: rs.getString(rs.getColumnIndex('type')) as GraphNodeType,
        name: rs.getString(rs.getColumnIndex('name')),
        aliases: aliasesText.length > 0 ? aliasesText.split(' ') : [],
        rank: rs.getDouble(rs.getColumnIndex('rank')),
      })
    }
    rs.close()
    return list
  }

  static async edges(context: common.Context): Promise<GraphEdge[]> {
    const store: relationalStore.RdbStore = await DataImportService.open(context)
    const rs: relationalStore.ResultSet = await store.querySql(
      `SELECT id, src, dst, rel, weight, evidence FROM ${Tables.GRAPH_EDGES}`
    )
    const list: GraphEdge[] = []
    while (rs.goToNextRow()) {
      const evidence: string = rs.getString(rs.getColumnIndex('evidence'))
      list.push({
        id: rs.getString(rs.getColumnIndex('id')),
        from: rs.getString(rs.getColumnIndex('src')),
        to: rs.getString(rs.getColumnIndex('dst')),
        rel: rs.getString(rs.getColumnIndex('rel')) as GraphRelation,
        weight: rs.getDouble(rs.getColumnIndex('weight')),
        evidence,
      })
    }
    rs.close()
    return list
  }

  /** 节点所属的条目 id（用于「双击跳详情」）。
   *
   *  Site 节点的 id 就是 itemId；其余节点（城市/时代/文物…）没有对应条目。
   */
  static itemIdOf(node: GraphNode): string {
    if (node.type === 'Site') {
      return node.id
    }
    return ''
  }
}
