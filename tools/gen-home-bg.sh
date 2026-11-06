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
OUT_TILE="$IMG_DIR/river-tile.webp"
OUT_FADE="$IMG_DIR/river-fade.webp"
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
