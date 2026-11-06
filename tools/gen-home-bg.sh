#!/bin/zsh
# 首页背景「淡纹」资源生成器：river-tile.webp + river-fade.webp
#
# 背景：river-bg.webp（1080x6000）等比铺满只有 2000vp，够盖卷首与前几条；
# 80 条档案内容约 19000vp，超长单图（1080x57000）解码要 250MB 内存，不可行。
# 所以超出段改用本脚本生成的小 tile 竖向平铺（ImageRepeat.Y），解码仅 6MB。
#
# 两张产物：
#   river-tile.webp  1080x1440，严格周期（顶行≈底行），淡于卷首的水纹
#   river-fade.webp  1080x480，一次性过渡带：卷首末段 → tile 顶行，抹掉硬切
#
# 淡纹而不是原样：卷首已经有完整水墨河道，长尾只需要「河还在」的暗示。
# 取深水段后与纸色 65/35 混合，平均色压到接近纸色，正文对比度不受影响。
#
# 用法：tools/gen-home-bg.sh
set -euo pipefail

IMG_DIR="$(cd "$(dirname "$0")/.." && pwd)/harmony/YellowRiverArchive/entry/src/main/resources/rawfile/img"
SRC="$IMG_DIR/river-bg.webp"
# tile 与过渡带只是合成用的中间产物，写到 derived/（已 gitignore），
# 不进 rawfile —— 否则会被打进 HAP 而运行时根本用不到
DERIVED="$(cd "$(dirname "$0")/.." && pwd)/packages/data/derived"
mkdir -p "$DERIVED"
OUT_TILE="$DERIVED/river-tile.webp"
OUT_FADE="$DERIVED/river-fade.webp"
TMP="$(mktemp -d)"
trap "rm -rf '$TMP'" EXIT

H=1440    # tile 高（480vp @3x）
K=240     # 周期溶合带宽（80vp）
FADE=480  # 过渡带高（160vp）
PAPER='#F3EADB'

# ---- 1) 取深水段并与纸色混合成淡纹 ----
magick "$SRC" -crop 1080x${H}+0+4400 +repage "$TMP/deep.png"
magick -size 1080x${H} "xc:$PAPER" "$TMP/deep.png" \
  -define compose:args=65,35 -compose blend -composite "$TMP/pale.png"

# ---- 2) 周期化：底部 K 行与顶部 K 行交叉溶解 ----
magick -size 1080x${K} gradient:black-white "$TMP/mask.png"
magick "$TMP/pale.png" -crop 1080x${K}+0+$((H-K)) +repage "$TMP/bot.png"
# 顶带要**竖向翻转**：溶合带自上而下是走向「回绕点」（row 0）的，
# 不翻转的话末行等于顶带第 K 行，tile 顶≠底，平铺处仍会跳变
magick "$TMP/pale.png" -crop 1080x${K}+0+0 +repage -flip "$TMP/top.png"
magick "$TMP/top.png" "$TMP/mask.png" -alpha off -compose CopyOpacity -composite "$TMP/top_a.png"
magick "$TMP/bot.png" "$TMP/top_a.png" -compose Over -composite "$TMP/joint.png"
magick "$TMP/pale.png" -crop 1080x$((H-K))+0+0 +repage "$TMP/body.png"
magick "$TMP/body.png" "$TMP/joint.png" -append "$TMP/tile.png"

# ---- 3) 过渡带：卷首末段 → tile 顶行 ----
# 过渡带的起点必须是卷首的**最后一行**（平铺处上方就是它），
# 取末行复制成条带，保证 y=2000vp 处颜色完全接上
magick "$SRC" -crop 1080x1+0+5999 +repage -resize 1080x${FADE}\! "$TMP/head.png"
magick "$TMP/tile.png" -crop 1080x1+0+0 +repage -resize 1080x${FADE}\! "$TMP/goal.png"
magick -size 1080x${FADE} gradient:black-white "$TMP/fmask.png"
magick "$TMP/goal.png" "$TMP/fmask.png" -alpha off -compose CopyOpacity -composite "$TMP/goal_a.png"
magick "$TMP/head.png" "$TMP/goal_a.png" -compose Over -composite "$TMP/fade.png"

# ---- 4) 导出 ----
magick "$TMP/tile.png" -quality 82 -define webp:method=6 "$OUT_TILE"
magick "$TMP/fade.png" -quality 82 -define webp:method=6 "$OUT_FADE"

echo "== 产物 =="
magick identify "$OUT_TILE" "$OUT_FADE"
echo "== 接缝自检 =="
magick "$OUT_TILE" -format "tile 平均色 %[pixel:p{540,720}]\n" info:
magick "$OUT_TILE" -format "tile 顶行   %[pixel:p{150,0}]\n" info:
magick "$OUT_TILE" -format "tile 底行   %[pixel:p{150,1439}]\n" info:
magick "$OUT_FADE" -format "fade 顶行   %[pixel:p{150,0}]\n" info:
magick "$OUT_FADE" -format "fade 底行   %[pixel:p{150,479}]\n" info:
magick "$SRC" -format "卷首末行 %[pixel:p{150,5999}]\n" info:

# ---- 5) 合成长图 river-bg-long.webp ----
# 为什么需要它：真机实测 `.background(CustomBuilder)` 不渲染（同一位置
# `.background('#FF0000')` 能铺满，`.overlay(builder)` 能出画），
# 三层叠加方案在 ArkTS 侧落不了地。于是把「卷首 + 过渡 + N 次 tile」
# 在生成期合成成一张图，运行时仍走已验证的 backgroundImage + Cover。
#
# 宽度取 270（屏宽 360vp 的 3/4）：内容 19000vp 时解码约 15.7MB，
# 单张 1080x57000 要 250MB，不可行。代价是卷首水墨会软一些 ——
# 所以只在内容超过 2000vp 时才用它，5 条时仍走清晰的原图。
LONG_H_VP="${1:-19500}"          # 目标内容高度（vp）
TILE_VP=480                       # tile 铺满后的高
HEAD_VP=2000
FADE_VP=160
W=270
N_TILE=$(( (LONG_H_VP - HEAD_VP - FADE_VP + TILE_VP - 1) / TILE_VP ))
TOTAL_VP=$(( HEAD_VP + FADE_VP + N_TILE * TILE_VP ))

magick "$SRC" -resize ${W}x$(( W * HEAD_VP / 360 ))\! "$TMP/head_s.png"
magick "$OUT_FADE" -resize ${W}x$(( W * FADE_VP / 360 ))\! "$TMP/fade_s.png"
magick "$OUT_TILE" -resize ${W}x$(( W * TILE_VP / 360 ))\! "$TMP/tile_s.png"
# -duplicate n 产出 n+1 帧，所以要 N-1（实测 -clone 0-N 在单帧上会被截断成 2 帧）
magick "$TMP/tile_s.png" -duplicate $(( N_TILE - 1 )) -append "$TMP/tiles.png"
magick "$TMP/head_s.png" "$TMP/fade_s.png" "$TMP/tiles.png" -append \
  -quality 80 -define webp:method=6 "$IMG_DIR/river-bg-long.webp"
echo "== 合成长图 =="
magick identify "$IMG_DIR/river-bg-long.webp"
echo "   覆盖 $TOTAL_VP vp（卷首 $HEAD_VP + 过渡 $FADE_VP + tile ${N_TILE}x${TILE_VP}）"
