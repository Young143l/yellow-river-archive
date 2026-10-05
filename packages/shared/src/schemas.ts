/**
 * 运行时校验（Zod）。
 *
 * 用途：数据流水线质检、服务端请求校验、端侧预置包自检。
 * 不生成到端侧（端侧只用类型，不引入 zod）。
 *
 * 约定：schema 的推断类型必须与 models.ts 的接口一致，
 * 下方 Check* 类型别名会在编译期做双向校验，不一致时直接报错。
 */

import { z } from 'zod'

import { CITIES, COLLECT_TARGET_TYPES, ERAS, HERITAGE_TYPES, LEVELS, SECTIONS } from './constants'
import type { Chunk, GraphEdge, GraphNode, HeritageItem, SimilarEntry } from './models'
import type { PresetMeta } from './preset'

// ---------------------------------------------------------------------------
// 编译期一致性断言
// ---------------------------------------------------------------------------

/** 双向可赋值检查：不一致时该类型别名会报错 */
type Exact<A, B> = [A] extends [B] ? ([B] extends [A] ? true : false) : false
type Assert<T extends true> = T

// ---------------------------------------------------------------------------
// 基础
// ---------------------------------------------------------------------------

const CitySchema = z.enum(CITIES)
const EraSchema = z.enum(ERAS)
const HeritageTypeSchema = z.enum(HERITAGE_TYPES)
const LevelSchema = z.enum(LEVELS)
const SectionSchema = z.enum(SECTIONS)

/** ISO 日期 yyyy-MM-dd */
const IsoDateSchema = z.string().regex(/^\d{4}-\d{2}-\d{2}$/)

// ---------------------------------------------------------------------------
// 档案条目
// ---------------------------------------------------------------------------

const HeritageEventSchema = z.object({
  year: z.string().min(1),
  title: z.string().min(1),
  desc: z.string().min(1),
})

const HeritagePoemSchema = z.object({
  title: z.string().min(1),
  author: z.string().min(1),
  dynasty: z.string().min(1),
  content: z.string().min(1),
  note: z.string().optional(),
})

const TravelInfoSchema = z.object({
  hours: z.string().optional(),
  ticket: z.string().optional(),
  best: z.string().optional(),
  tips: z.array(z.string()).readonly(),
})

const ArtifactSchema = z.object({
  id: z.string().min(1),
  name: z.string().min(1),
  desc: z.string().min(1),
  museum: z.string().optional(),
})

const HeritageFigureSchema = z.object({
  name: z.string().min(1),
  role: z.string().min(1),
  desc: z.string().min(1),
})

const HeritageImageSchema = z.object({
  url: z.string().min(1),
  caption: z.string().min(1),
  /** 版权留痕：credit 与 license 均不得为空 */
  credit: z.string().min(1),
  license: z.string().min(1),
})

const SourceRefSchema = z.object({
  title: z.string().min(1),
  url: z.string().min(1),
  accessedAt: IsoDateSchema,
})

export const HeritageItemSchema = z.object({
  id: z.string().regex(/^[a-z]{2,3}-[a-z0-9-]+$/),
  name: z.string().min(1),
  aliases: z.array(z.string()).readonly(),

  city: CitySchema,
  era: EraSchema,
  eraRange: z.tuple([z.number(), z.number()]).optional(),
  types: z.array(HeritageTypeSchema).min(1).readonly(),
  level: LevelSchema.optional(),

  geo: z.object({
    lat: z.number().min(-90).max(90),
    lng: z.number().min(-180).max(180),
  }),

  summary: z.string().min(10).max(120),
  intro: z.string().min(200).max(1200),
  archaeology: z.string().min(150).max(900),
  events: z.array(HeritageEventSchema).readonly(),
  poems: z.array(HeritagePoemSchema).readonly(),
  travel: TravelInfoSchema.optional(),
  artifacts: z.array(ArtifactSchema).readonly(),
  figures: z.array(HeritageFigureSchema).readonly(),
  images: z.array(HeritageImageSchema).min(1).readonly(),

  keywords: z.array(z.string()).min(3).readonly(),
  sources: z.array(SourceRefSchema).min(1).readonly(),
})

type _CheckHeritageItem = Assert<Exact<z.infer<typeof HeritageItemSchema>, HeritageItem>>

// ---------------------------------------------------------------------------
// 检索与图谱
// ---------------------------------------------------------------------------

export const ChunkSchema = z.object({
  id: z.string().min(1),
  itemId: z.string().min(1),
  section: SectionSchema,
  seq: z.number().int().min(0),
  text: z.string().min(20),
  tokens: z.array(z.string()).readonly(),
})

type _CheckChunk = Assert<Exact<z.infer<typeof ChunkSchema>, Chunk>>

export const GraphNodeSchema = z.object({
  id: z.string().min(1),
  type: z.enum(['Site', 'Era', 'City', 'Type', 'Artifact', 'Figure', 'Event', 'Poem', 'Theme', 'Museum']),
  name: z.string().min(1),
  aliases: z.array(z.string()).readonly(),
  rank: z.number().optional(),
})

type _CheckGraphNode = Assert<Exact<z.infer<typeof GraphNodeSchema>, GraphNode>>

export const GraphEdgeSchema = z.object({
  id: z.string().min(1),
  from: z.string().min(1),
  to: z.string().min(1),
  rel: z.enum([
    'locatedIn',
    'belongsToEra',
    'hasType',
    'unearthed',
    'relatedFigure',
    'hasPoem',
    'occurredEvent',
    'culturalLink',
    'nearby',
    'collectedAt',
  ]),
  weight: z.number().min(0).max(1),
  evidence: z.string().optional(),
})

type _CheckGraphEdge = Assert<Exact<z.infer<typeof GraphEdgeSchema>, GraphEdge>>

export const SimilarEntrySchema = z.object({
  itemId: z.string().min(1),
  neighbors: z
    .array(
      z.object({
        id: z.string().min(1),
        score: z.number().min(0).max(1),
        reason: z.string().min(1),
      })
    )
    .readonly(),
})

type _CheckSimilarEntry = Assert<Exact<z.infer<typeof SimilarEntrySchema>, SimilarEntry>>

// ---------------------------------------------------------------------------
// 预置包
// ---------------------------------------------------------------------------

export const PresetMetaSchema = z.object({
  dataVersion: z.string().regex(/^\d{4}\.\d{1,2}\.\d{1,2}$/),
  contentHash: z.string().min(8),
  generatedAt: z.string().min(1),
  itemCount: z.number().int().min(0),
  chunkCount: z.number().int().min(0),
  imageCount: z.number().int().min(0),
  vocabSize: z.number().int().min(0),
  sourceDeclarations: z.array(z.string()).readonly(),
  pipelineVersion: z.string().min(1),
})

type _CheckPresetMeta = Assert<Exact<z.infer<typeof PresetMetaSchema>, PresetMeta>>

// ---------------------------------------------------------------------------
// 校验入口
// ---------------------------------------------------------------------------

export interface ValidateOutcome<T> {
  readonly ok: boolean
  readonly value?: T
  readonly issues: readonly { readonly path: string; readonly message: string }[]
}

/** 校验单个条目，返回结构化结果而非抛异常（流水线质检用） */
export function validateHeritageItem(input: unknown): ValidateOutcome<HeritageItem> {
  const result = HeritageItemSchema.safeParse(input)
  if (result.success) {
    return { ok: true, value: result.data, issues: [] }
  }
  return {
    ok: false,
    issues: result.error.issues.map((i) => ({
      path: i.path.join('.'),
      message: i.message,
    })),
  }
}

export { CitySchema, EraSchema, HeritageTypeSchema, LevelSchema, SectionSchema }
