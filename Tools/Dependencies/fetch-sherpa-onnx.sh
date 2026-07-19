#!/bin/sh
set -eu

version="1.13.2"
expected="41e71dd73424394475d5f1ff176a21beaf1ce2b6466120110823adfc850b6b02"
archive="${TMPDIR:-/tmp}/sherpa-onnx-${version}-macos-universal-shared.tar.bz2"
url="https://github.com/k2-fsa/sherpa-onnx/releases/download/v${version}/sherpa-onnx-v${version}-macos-universal-shared.tar.bz2"
destination="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)/Vendor"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

curl --fail --location --proto '=https' --tlsv1.2 "$url" --output "$archive"
actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
test "$actual" = "$expected" || { echo "sherpa-onnx checksum mismatch" >&2; exit 1; }
tar -xjf "$archive" -C "$work"
distribution="$(find "$work" -type f -name 'libsherpa-onnx-c-api.dylib' -print -quit | xargs dirname)"
headers="$work/headers"
mkdir -p "$headers"
curl --fail --location --proto '=https' --tlsv1.2 \
  "https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/13d0ae6c539d2809d32f5eaa3ef1db0c459d0b24/sherpa-onnx/c-api/c-api.h" \
  --output "$headers/c-api.h"
rm -rf "$destination/SherpaOnnx.xcframework" "$destination/OnnxRuntime.xcframework"
xcodebuild -create-xcframework \
  -library "$distribution/libsherpa-onnx-c-api.dylib" -headers "$headers" \
  -output "$destination/SherpaOnnx.xcframework"
xcodebuild -create-xcframework \
  -library "$distribution/libonnxruntime.1.24.4.dylib" \
  -output "$destination/OnnxRuntime.xcframework"
lipo -verify_arch x86_64 arm64 "$destination/SherpaOnnx.xcframework/macos-arm64_x86_64/libsherpa-onnx-c-api.dylib"
lipo -verify_arch x86_64 arm64 "$destination/OnnxRuntime.xcframework/macos-arm64_x86_64/libonnxruntime.1.24.4.dylib"
