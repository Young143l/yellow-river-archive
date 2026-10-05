/**
 * @yra/shared —— 数据契约唯一来源
 *
 * 导出顺序：常量 → 模型 → 预置包 → 接口 → 校验
 *
 * 注意：constants / models / preset / api 四个文件是"纯声明"文件，
 * 会被 tools/gen 原样生成为端侧 .ets；schemas 只在服务端与工具链使用。
 */

export * from './constants'
export * from './models'
export * from './preset'
export * from './api'
export {
  HeritageItemSchema,
  ChunkSchema,
  GraphNodeSchema,
  GraphEdgeSchema,
  SimilarEntrySchema,
  PresetMetaSchema,
  CitySchema,
  EraSchema,
  HeritageTypeSchema,
  LevelSchema,
  SectionSchema,
  validateHeritageItem,
} from './schemas'
export type { ValidateOutcome } from './schemas'
