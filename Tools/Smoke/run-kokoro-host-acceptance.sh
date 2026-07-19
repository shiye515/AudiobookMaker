#!/bin/sh
set -eu

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "usage: run-kokoro-host-acceptance MODEL_ARCHIVE [OUTPUT_DIRECTORY]" >&2
  exit 64
fi

repository="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
archive="$1"
architecture="$(uname -m)"
output="${2:-$repository/build/acceptance/kokoro-$architecture}"

case "$architecture" in
  arm64|x86_64) ;;
  *) echo "unsupported host architecture: $architecture" >&2; exit 65 ;;
esac

test -f "$archive" || { echo "model archive not found: $archive" >&2; exit 66; }
test ! -e "$output/Kokoro-Host-Smoke.xcresult" || {
  echo "result bundle already exists: $output/Kokoro-Host-Smoke.xcresult" >&2
  exit 67
}

mkdir -p "$output"
work="$(mktemp -d "${TMPDIR:-/tmp}/AudiobookMaker-Kokoro-Acceptance.XXXXXX")"
trap 'rm -rf "$work"' EXIT

tar -xjf "$archive" -C "$work"
model_file="$(find "$work" -type f -name model.int8.onnx -print -quit)"
test -n "$model_file" || { echo "model.int8.onnx missing from archive" >&2; exit 68; }
model_directory="$(dirname "$model_file")"

sherpa_root="$repository/Vendor/SherpaOnnx.xcframework/macos-arm64_x86_64"
onnx_root="$repository/Vendor/OnnxRuntime.xcframework/macos-arm64_x86_64"
benchmark="$output/kokoro-benchmark"

clang -O2 -arch "$architecture" \
  -I "$sherpa_root/Headers" \
  "$repository/Tools/Smoke/kokoro-benchmark.c" \
  "$sherpa_root/libsherpa-onnx-c-api.dylib" \
  "$onnx_root/libonnxruntime.1.24.4.dylib" \
  -Wl,-rpath,"$sherpa_root" -Wl,-rpath,"$onnx_root" \
  -o "$benchmark"

{
  echo "host_architecture=$architecture"
  echo "os_version=$(sw_vers -productVersion)"
  echo "model_archive_sha256=$(shasum -a 256 "$archive" | awk '{print $1}')"
  file "$benchmark"
} > "$output/environment.txt"

DYLD_LIBRARY_PATH="$sherpa_root:$onnx_root" \
  "$benchmark" "$model_directory" "$output/audio" \
  > "$output/benchmark.txt"

KOKORO_MODEL_ARCHIVE="$archive" xcodebuild \
  -project "$repository/AudiobookMaker.xcodeproj" \
  -scheme AudiobookMaker \
  -destination 'platform=macOS' \
  -derivedDataPath "$output/DerivedData" \
  -resultBundlePath "$output/Kokoro-Host-Smoke.xcresult" \
  '-only-testing:AudiobookMakerTests/KokoroIntegrationTests/realKokoroSmokeTestWhenArchiveIsProvided()' \
  test \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=

echo "Kokoro $architecture acceptance completed: $output"
