/**
 * AI 服务实测：连通性、可用模型、维度、批量上限、限流、用量。
 *
 * 为什么要有这个脚本：模型名、维度档位、单次批量上限这些参数各厂商文档口径不同，
 * 且会随版本变化。与其照抄文档，不如打一次真实请求量出来——实测结果写入
 * docs/ai-providers.md，作为全局配置依据。
 *
 * 命令：pnpm ai:check
 */

import { DashScopeEmbedding, DashScopeRerank, DeepSeekLlm, readEmbeddingEnv, readEnv } from '@yra/ai'

interface CheckLine {
  readonly ok: boolean
  /** 探测项不计入失败统计（如“旧版模型不可用”“超过批量上限”这类预期结论） */
  readonly probe: boolean
  readonly label: string
  readonly detail: string
}

const lines: CheckLine[] = []

function record(ok: boolean, label: string, detail: string): void {
  lines.push({ ok, probe: false, label, detail })
}

function probe(ok: boolean, label: string, detail: string): void {
  lines.push({ ok, probe: true, label, detail })
}

async function checkEmbedding(model: string, dim: number): Promise<void> {
  const env = readEmbeddingEnv()
  const provider = new DashScopeEmbedding({ ...env, embeddingModel: model, embeddingDim: dim }, 10)
  const sample: string[] = ['二里头遗址', '唐三彩的主要产地', '仰韶文化']

  const started: number = Date.now()
  const vectors: number[][] = await provider.embed(sample)
  const elapsed: number = Date.now() - started

  const first: number[] | undefined = vectors[0]
  record(
    first !== undefined && first.length === dim,
    `${model} 维度 ${dim}`,
    `${vectors.length} 条 / ${elapsed}ms / 实际维度 ${first?.length ?? 0} / token ${provider.usage.tokens}`
  )
}

async function probeEmbeddingBatch(model: string, dim: number, size: number): Promise<boolean> {
  const env = readEmbeddingEnv()
  const provider = new DashScopeEmbedding({ ...env, embeddingModel: model, embeddingDim: dim }, size)
  const texts: string[] = Array.from({ length: size }, (_, i) => `测试文本第 ${i + 1} 条`)
  try {
    await provider.embed(texts)
    return true
  } catch {
    return false
  }
}

async function checkRerank(model: string): Promise<void> {
  const env = readEmbeddingEnv()
  const provider = new DashScopeRerank({ ...env, rerankModel: model })
  const docs: string[] = [
    '二里头遗址位于洛阳偃师，学界多认为是夏代晚期都邑。',
    '巩义窑址是唐三彩的主要产地。',
    '开封铁塔是北宋琉璃砖塔。',
  ]
  const started: number = Date.now()
  const hits = await provider.rerank('唐三彩产自哪里', docs, 3)
  const elapsed: number = Date.now() - started
  const top: string = hits.length > 0 ? `top1=#${hits[0]?.index}(${hits[0]?.score.toFixed(3)})` : '无结果'
  record(hits.length > 0, `rerank ${model}`, `${hits.length} 条 / ${elapsed}ms / ${top}`)
}

async function checkLlm(): Promise<void> {
  const env = readEnv()
  const provider = new DeepSeekLlm(env)

  const started: number = Date.now()
  const answer: string = await provider.complete(
    [
      { role: 'system', content: '你是黄河文化助手，回答控制在 40 字以内。' },
      { role: 'user', content: '二里头遗址在哪个城市？' },
    ],
    { temperature: 0.2, maxTokens: 128, timeoutMs: 60_000 }
  )
  const elapsed: number = Date.now() - started
  record(
    answer.length > 0,
    `llm ${provider.model} 非流式`,
    `${elapsed}ms / token ${provider.usage.tokens} / 回答：${answer.trim().slice(0, 40)}`
  )

  // 流式：测首字延迟与总时长
  const streamStarted: number = Date.now()
  let firstAt: number = 0
  let text: string = ''
  const iterable: AsyncIterable<string> = await provider.stream(
    [
      { role: 'system', content: '你是黄河文化助手，回答控制在 30 字以内。' },
      { role: 'user', content: '用一句话介绍唐三彩。' },
    ],
    { temperature: 0.2, maxTokens: 96, timeoutMs: 60_000 }
  )
  for await (const delta of iterable) {
    if (firstAt === 0) {
      firstAt = Date.now() - streamStarted
    }
    text += delta
  }
  const total: number = Date.now() - streamStarted
  record(
    text.length > 0,
    `llm ${provider.model} 流式`,
    `首字 ${firstAt}ms / 总 ${total}ms / 回答：${text.trim().slice(0, 40)}`
  )
}

async function main(): Promise<void> {
  const env = readEnv()
  console.log('[ai:check] 开始实测（配置见 docs/env-template.md）')
  console.log(`  嵌入模型（配置值）：${env.embeddingModel} @ ${env.embeddingDim} 维`)
  console.log(`  重排模型（配置值）：${env.rerankModel}`)
  console.log(`  生成模型（配置值）：${env.deepseekModel}`)
  console.log('')

  // 1. 配置中的嵌入模型
  try {
    await checkEmbedding(env.embeddingModel, env.embeddingDim)
  } catch (err) {
    record(false, `嵌入 ${env.embeddingModel}`, (err as Error).message.slice(0, 200))
  }

  // 2. 备选嵌入模型与维度档位
  const embeddingCandidates: { model: string; dim: number }[] = [
    { model: 'text-embedding-v4', dim: 1024 },
    { model: 'text-embedding-v4', dim: 512 },
    { model: 'text-embedding-v3', dim: 1024 },
    { model: 'text-embedding-v3', dim: 512 },
  ]
  for (const candidate of embeddingCandidates) {
    if (candidate.model === env.embeddingModel && candidate.dim === env.embeddingDim) {
      continue
    }
    try {
      await checkEmbedding(candidate.model, candidate.dim)
    } catch (err) {
      probe(false, `${candidate.model} 维度 ${candidate.dim}`, (err as Error).message.slice(0, 120))
    }
  }

  // 3. 批量上限探测
  for (const size of [10, 25]) {
    const ok: boolean = await probeEmbeddingBatch(env.embeddingModel, env.embeddingDim, size)
    probe(ok, `批量 ${size} 条`, ok ? '可用' : '被拒绝（超过上限）')
  }

  // 4. 重排
  for (const model of [env.rerankModel, 'gte-rerank-v2', 'gte-rerank']) {
    try {
      await checkRerank(model)
    } catch (err) {
      probe(false, `rerank ${model}`, (err as Error).message.slice(0, 150))
    }
  }

  // 5. 生成
  try {
    await checkLlm()
  } catch (err) {
    record(false, `llm ${env.deepseekModel}`, (err as Error).message.slice(0, 200))
  }

  console.log('[ai:check] 实测结果')
  for (const line of lines) {
    const tag: string = line.ok ? 'OK  ' : line.probe ? 'INFO' : 'FAIL'
    console.log(`  ${tag} ${line.label.padEnd(28, ' ')} ${line.detail}`)
  }

  const failures: number = lines.filter((l) => !l.ok && !l.probe).length
  const infos: number = lines.filter((l) => !l.ok && l.probe).length
  console.log('')
  console.log(`[ai:check] 通过 ${lines.length - failures - infos} 项，失败 ${failures} 项，探测结论 ${infos} 条`)
  if (failures > 0) {
    process.exitCode = 1
  }
}

main().catch((err: unknown) => {
  console.error('[ai:check] 执行失败：', err instanceof Error ? err.message : err)
  process.exit(1)
})
