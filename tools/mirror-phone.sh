#!/usr/bin/env bash
#
# 真机投屏（近似实时）。
#
# 为什么不用 scrcpy：HarmonyOS 没有 ADB，系统里也没有 screenrecord，
# 唯一可用的画面出口是 snapshot_display（截图）。所以取帧 → 本地网页轮询。
# 帧率约 2 帧/秒，够看清同步进度与列表变化；不适合高动态动画。
#
# 用法：tools/mirror-phone.sh [串号]
#      默认取 hdc list targets 里第一台非 127.0.0.1 的真机
# 停止：Ctrl-C
set -uo pipefail

HDC="${HDC:-$HOME/Library/OpenHarmony/Sdk/26.0.0/toolchains/hdc}"
PORT="${PORT:-8099}"
DIR="$(cd "$(dirname "$0")/.." && pwd)/.shots/mirror"
DEV="${1:-}"

if [ -z "$DEV" ]; then
  DEV="$("$HDC" list targets 2>/dev/null | grep -v '127.0.0.1' | head -1)"
fi
if [ -z "$DEV" ]; then
  echo "没找到真机，检查 USB 连接与 hdc list targets"
  exit 1
fi

mkdir -p "$DIR"
cat > "$DIR/index.html" <<HTML
<!doctype html><meta charset="utf-8">
<title>真机投屏 ${DEV}</title>
<style>
  html,body{margin:0;background:#1b1b1b;height:100%;display:flex;align-items:center;justify-content:center}
  img{max-height:100vh;max-width:100vw;image-rendering:auto}
</style>
<img id="v" src="frame.jpg">
<script>
  // 持续换 src 并加时间戳绕过缓存
  const v = document.getElementById('v')
  setInterval(() => { v.src = 'frame.jpg?t=' + Date.now() }, 250)
</script>
HTML

echo "设备 $DEV"
echo "用浏览器打开 http://127.0.0.1:${PORT}/ （Safari/Chrome 均可）"
echo "停止按 Ctrl-C"

python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$DIR" >/dev/null 2>&1 &
SRV_PID=$!

cleanup() {
  kill "$SRV_PID" 2>/dev/null
}
trap cleanup EXIT INT TERM

while :; do
  if "$HDC" -t "$DEV" shell "snapshot_display -f /data/local/tmp/mirror.jpeg" >/dev/null 2>&1; then
    "$HDC" -t "$DEV" file recv /data/local/tmp/mirror.jpeg "$DIR/next.jpg" >/dev/null 2>&1 &&
      mv -f "$DIR/next.jpg" "$DIR/frame.jpg" 2>/dev/null
  fi
  sleep 0.15
done