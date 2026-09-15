#!/bin/zsh
# 构造迷你 EPUB 夹具并运行解析层校验（章节锚点切分）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$ROOT/scripts/make_epub_fixtures.py"
APP="$ROOT/build/Build/Products/Debug/abm.app/Contents/MacOS/abm"
if [[ ! -x "$APP" ]]; then
  # 回退到 DerivedData 默认路径
  APP="$(find ~/Library/Developer/Xcode/DerivedData -path '*/Debug/abm.app/Contents/MacOS/abm' 2>/dev/null | head -1)"
fi
if [[ -z "${APP:-}" || ! -x "$APP" ]]; then
  echo "找不到 abm 可执行文件，请先 xcodebuild build" >&2
  exit 2
fi
echo "using $APP"
"$APP" --verify-epub-split "$ROOT/scripts/fixtures"
