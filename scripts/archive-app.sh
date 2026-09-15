#!/bin/zsh
# Archive abm（CLI 备用）。GUI Product→Archive 自 speech-swift 本地 float32 补丁后也可用。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/build/abm.xcarchive}"
mkdir -p "$(dirname "$OUT")"
xcodebuild archive \
  -project "$ROOT/abm.xcodeproj" \
  -scheme abm \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$OUT" \
  ARCHS=arm64
echo "ARCHIVE → $OUT"
