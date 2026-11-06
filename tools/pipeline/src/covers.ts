/**
 * 程序化封面卡生成。
 *
 * 为什么不用 AI 生图：示意图必须与元数据严格一致（时代、类型是事实），
 * 模型画的文物造型可能与正文不符；程序化渲染零幻觉、零外部依赖、
 * 80 条一次出图，且版权台账天然干净（credit=本项目绘制）。
 *
 * 渲染管线：ImageMagick —— 纸纹底 + 时代色带 + 类型线描符号 + 宋体遗址名 + 朱砂章。
 */

import { spawnSync } from 'node:child_process'
import { readFileSync, writeFileSync } from 'node:fs'
import { basename, join } from 'node:path'

import type { HeritageItem } from '@yra/shared'

import { loadSites } from './load-sites'

const W: number = 1080
const H: number = 720

const INK: string = '#2E2A24'
const META: string = '#6B6152'
const SEAL_RED: string = '#B03A2E'
const SEAL_WHITE: string = '#F7F2E4'

/** 时代 → [主色, 深色]。矿物颜料色谱，与 Theme.ets 的青绿/赭石/朱砂一脉 */
const ERA_COLORS: Record<string, readonly [string, string]> = {
  仰韶: ['#A6622E', '#8A4F1F'],
  龙山: ['#54504A', '#3E3B36'],
  夏商: ['#35677C', '#285061'],
  周: ['#8C7440', '#6F5B2E'],
  汉唐: ['#5E8C6A', '#487053'],
  宋: ['#6F8F9C', '#567482'],
  宋以后: ['#8A7B6C', '#6E6154'],
}

/** 类型 → 线描符号（200×200 视窗，仅描线） */
const SYMBOLS: Record<string, string> = {
  都城遗址:
    'M 20,60 L 20,180 L 180,180 L 180,60 Z M 60,60 L 60,180 M 140,60 L 140,180 ' +
    'M 88,180 L 88,140 L 66,140 L 66,180 M 112,180 L 112,140 L 134,140 L 134,180',
  城址:
    'M 30,70 L 30,180 L 170,180 L 170,70 Z ' +
    'M 75,180 L 75,135 L 125,135 L 125,180',
  聚落遗址:
    'M 50,140 a 15,15 0 1,0 0.01,0 M 100,108 a 15,15 0 1,0 0.01,0 M 150,150 a 15,15 0 1,0 0.01,0 ' +
    'M 75,170 a 10,10 0 1,0 0.01,0 M 130,80 a 10,10 0 1,0 0.01,0',
  墓葬群:
    'M 15,170 A 85,70 0 0 1 185,170 M 50,170 A 50,42 0 0 1 150,170 M 10,170 L 190,170',
  窑址:
    'M 40,170 L 40,110 A 60,60 0 0 1 160,110 L 160,170 Z ' +
    'M 82,170 L 82,136 L 118,136 L 118,170',
  古建筑:
    'M 100,18 L 100,180 M 60,70 L 140,70 M 70,110 L 130,110 M 80,150 L 120,150 ' +
    'M 92,36 L 108,36 M 50,182 L 150,182',
  石窟寺:
    'M 30,170 L 30,112 A 24,24 0 0 1 78,112 L 78,170 M 122,170 L 122,112 A 24,24 0 0 1 170,112 L 170,170 ' +
    'M 62,170 L 62,86 A 38,38 0 0 1 138,86 L 138,170 M 18,170 L 182,170',
  碑刻:
    'M 78,26 L 122,26 L 122,150 L 78,150 Z M 58,150 L 142,150 M 68,170 L 132,170 ' +
    'M 90,58 L 110,58 M 90,80 L 110,80 M 90,102 L 110,102',
  祭祀址:
    'M 36,158 L 164,158 M 52,124 L 148,124 M 68,90 L 132,90 M 84,56 L 116,56 M 100,24 L 100,40',
  关隘遗址:
    'M 16,180 L 16,80 L 56,80 M 144,80 L 184,80 L 184,180 ' +
    'M 56,80 L 56,48 L 144,48 L 144,80 M 84,80 L 84,180 M 116,80 L 116,180',
}

/** 兜底符号（类型未登记时用聚落点群） */
const FALLBACK_SYMBOL: string = SYMBOLS['聚落遗址'] ?? ''

function eraColors(era: string): readonly [string, string] {
  return ERA_COLORS[era] ?? ['#8A7B6C', '#6E6154']
}

function symbolFor(item: HeritageItem): string {
  for (const t of item.types) {
    const s: string | undefined = SYMBOLS[t]
    if (s !== undefined) return s
  }
  return FALLBACK_SYMBOL
}

/** 遗址名字号：长名降字号，避免溢出 */
function nameSize(name: string): number {
  if (name.length <= 6) return 116
  if (name.length <= 8) return 96
  return 84
}

export interface CoverReport {
  readonly id: string
  readonly ok: boolean
  readonly message: string
}

function buildArgs(
  item: HeritageItem,
  fontPath: string,
  paperPath: string,
  outPath: string
): string[] {
  const [main, deep] = eraColors(item.era)
  const symbol: string = symbolFor(item)
  const meta: string = `${item.era} · ${item.city} · ${item.level}`

  return [
    '-background', '#F3EADB',
    // 纸纹底：tile 后叠一层半透明纸色，压住纹理使文字可读
    '(', '-size', `${W}x${H}`, `tile:${paperPath}`, ')',
    '(', '-size', `${W}x${H}`, 'xc:#F3EADB', '-alpha', 'on',
    '-channel', 'A', '-evaluate', 'set', '58%', '+channel', ')',
    '-compose', 'over', '-composite',
    // 时代色带：左侧竖条 + 底部淡染
    '-draw', `fill '${main}' rectangle 0,0 26,${H}`,
    '-draw', `fill '${main}' fill-opacity 0.14 rectangle 0,556,${W},${H}`,
    // 类型线描符号
    '-draw',
    `stroke '${deep}' stroke-width 9 stroke-linecap round stroke-linejoin round fill none ` +
      `translate 700,120 scale 1.25,1.25 path '${symbol}'`,
    // 遗址名 + 元信息行
    '-font', fontPath,
    '-fill', INK, '-pointsize', String(nameSize(item.name)),
    '-gravity', 'SouthWest', '-annotate', '+66+118', item.name,
    '-fill', META, '-pointsize', '40',
    '-gravity', 'SouthWest', '-annotate', '+70+56', meta,
    // 朱砂章
    '-draw', `fill '${SEAL_RED}' roundrectangle 920,592 1024,696 14,14`,
    '-fill', SEAL_WHITE, '-pointsize', '64',
    '-gravity', 'SouthEast', '-annotate', '+66+36', '河',
    '-quality', '82', '-define', 'webp:method=6', outPath,
  ]
}

/**
 * 把 yaml 里 images 段的占位措辞改成正式示意图署名。
 * 用户已确认允许脚本改 caption（2026-11-06）。
 */
function fixImageCredit(siteYamlPath: string, name: string): boolean {
  let text: string = readFileSync(siteYamlPath, 'utf8')
  const before: string = text
  text = text.replace(
    /caption: .*占位图.*$/m,
    `caption: ${name}示意图 · 本项目绘制`
  )
  text = text.replace(/credit: 占位图由本项目生成/, 'credit: 本项目绘制')
  text = text.replace(/license: 项目内部占位素材/, 'license: 自有版权（示意插图）')
  if (text === before) return false
  writeFileSync(siteYamlPath, text, 'utf8')
  return true
}

export async function generateCovers(opts: {
  sitesDir: string
  fontPath: string
  paperPath: string
  outDir: string
}): Promise<CoverReport[]> {
  const loaded = await loadSites(opts.sitesDir)
  const reports: CoverReport[] = []

  for (const item of loaded.items) {
    const url: string | undefined = item.images[0]?.url
    const outName: string = url !== undefined ? basename(url) : `${item.id}-1.webp`
    const outPath: string = join(opts.outDir, outName)

    const run = spawnSync('magick', buildArgs(item, opts.fontPath, opts.paperPath, outPath), {
      encoding: 'utf8',
    })
    const ok: boolean = run.status === 0
    reports.push({
      id: item.id,
      ok,
      message: ok ? outName : (run.stderr || 'magick 失败').slice(0, 120),
    })
  }
  return reports
}

export { fixImageCredit }
