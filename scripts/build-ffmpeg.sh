#!/bin/zsh
# 构建极简静态 ffmpeg（仅 MP4/M4A 容器读写 + ffmetadata），产物拷入应用包 Resources。
# 产物 abm/Tools/ffmpeg 与许可证文本随应用分发；已在 .gitignore 排除。
set -euo pipefail

FF_VERSION="8.1.2"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/build/ffmpeg-src"
OUT_DIR="$ROOT/abm/Tools"
TARBALL="$BUILD_DIR/ffmpeg-$FF_VERSION.tar.xz"
URL="https://ffmpeg.org/releases/ffmpeg-$FF_VERSION.tar.xz"

mkdir -p "$BUILD_DIR" "$OUT_DIR"

if [ ! -f "$TARBALL" ]; then
  echo "[1/4] 下载源码 $URL"
  curl -fL --retry 3 -o "$TARBALL" "$URL"
fi

echo "[2/4] 解压"
rm -rf "$BUILD_DIR/ffmpeg-$FF_VERSION"
tar -xf "$TARBALL" -C "$BUILD_DIR"
cd "$BUILD_DIR/ffmpeg-$FF_VERSION"

echo "[3/4] 配置（静态、极简：mov/ipot 容器 + ffmetadata + file 协议）"
./configure \
  --disable-everything \
  --disable-doc \
  --disable-debug \
  --disable-network \
  --disable-autodetect \
  --disable-x86asm \
  --disable-shared \
  --enable-static \
  --enable-zlib \
  --enable-ffmpeg \
  --enable-protocol=file \
  --enable-protocol=pipe \
  --enable-demuxer=mov \
  --enable-demuxer=ffmetadata \
  --enable-demuxer=concat \
  --enable-demuxer=wav \
  --enable-demuxer=image2 \
  --enable-muxer=ipod \
  --enable-muxer=mov \
  --enable-bsf=aac_adtstoasc \
  --enable-decoder=mjpeg \
  --enable-decoder=png \
  --enable-decoder=pcm_s16le \
  --enable-encoder=aac \
  --enable-encoder=mjpeg \
  --enable-filter=aresample \
  --enable-filter=aformat \
  --enable-filter=anull \
  --pkg-config-flags=--static

echo "[4/4] 编译"
make -j"$(sysctl -n hw.ncpu)" ffmpeg

cp -f ffmpeg "$OUT_DIR/ffmpeg"
cp -f COPYING.LGPLv2.1 "$OUT_DIR/ffmpeg-LICENSE" 2>/dev/null || cp -f COPYING.GPLv2 "$OUT_DIR/ffmpeg-LICENSE"
chmod +x "$OUT_DIR/ffmpeg"

# 预置 Hardened Runtime adhoc 签名（Archive 时工程脚本会用开发证书重签）
codesign --force --sign - --options runtime --identifier com.shifenniu.abm.ffmpeg "$OUT_DIR/ffmpeg" || true

echo "产物：$OUT_DIR/ffmpeg ($(du -h "$OUT_DIR/ffmpeg" | cut -f1))"
codesign -dv "$OUT_DIR/ffmpeg" 2>&1 | grep -E "flags|Identifier|Signature" || true
"$OUT_DIR/ffmpeg" -version | head -1
