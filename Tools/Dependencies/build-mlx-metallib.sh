#!/bin/bash

set -euo pipefail

if [[ -z "${BUILD_DIR:-}" || -z "${TARGET_BUILD_DIR:-}" || -z "${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}" ]]; then
  echo "error: build-mlx-metallib.sh must run from an Xcode build phase" >&2
  exit 1
fi

SOURCE_PACKAGES_DIR="${BUILD_DIR%%/Build/*}/SourcePackages"
MLX_SWIFT_DIR="$SOURCE_PACKAGES_DIR/checkouts/mlx-swift"
KERNELS_DIR="$MLX_SWIFT_DIR/Source/Cmlx/mlx/mlx/backend/metal/kernels"
OUTPUT_DIR="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/MLX"
OUTPUT_METALLIB="$OUTPUT_DIR/mlx.metallib"
HASH_FILE="$DERIVED_FILE_DIR/mlx.metallib.sources.sha256"

if [[ ! -d "$KERNELS_DIR" ]]; then
  echo "error: MLX Metal kernels are missing at $KERNELS_DIR" >&2
  echo "Resolve Swift packages before building the app." >&2
  exit 1
fi

if ! xcrun --find metal >/dev/null 2>&1 || ! xcrun --find metallib >/dev/null 2>&1; then
  echo "error: the Xcode Metal Toolchain is unavailable" >&2
  echo "Run: xcodebuild -downloadComponent MetalToolchain" >&2
  exit 1
fi

METAL_SOURCES=()
while IFS= read -r SOURCE; do
  METAL_SOURCES+=("$SOURCE")
done < <(find "$KERNELS_DIR" -type f -name '*.metal' ! -name '*_nax.metal' | LC_ALL=C sort)
if [[ ${#METAL_SOURCES[@]} -eq 0 ]]; then
  echo "error: no MLX Metal sources found under $KERNELS_DIR" >&2
  exit 1
fi

CURRENT_HASH="$({
  find "$KERNELS_DIR" -type f \( -name '*.metal' -o -name '*.h' \) ! -name '*_nax.metal' | LC_ALL=C sort | xargs cat
  printf '%s' "${SDKROOT:-unknown-sdk}|${CONFIGURATION:-unknown-configuration}"
} | shasum -a 256 | awk '{print $1}')"

if [[ -f "$OUTPUT_METALLIB" && -f "$HASH_FILE" ]] &&
   [[ "$(<"$HASH_FILE")" == "$CURRENT_HASH" ]]; then
  echo "MLX Metal library is current: $OUTPUT_METALLIB"
  exit 0
fi

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/audiobookmaker-mlx.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT

AIR_FILES=()
for SOURCE in "${METAL_SOURCES[@]}"; do
  RELATIVE_PATH="${SOURCE#"$KERNELS_DIR/"}"
  SOURCE_KEY="$(printf '%s' "$RELATIVE_PATH" | shasum -a 256 | cut -c1-16)"
  AIR_FILE="$TEMP_DIR/$SOURCE_KEY.air"
  xcrun -sdk macosx metal \
    -x metal \
    -Wall \
    -Wextra \
    -fno-fast-math \
    -Wno-c++17-extensions \
    -Wno-c++20-extensions \
    -c "$SOURCE" \
    -I"$KERNELS_DIR" \
    -I"$MLX_SWIFT_DIR/Source/Cmlx/mlx" \
    -o "$AIR_FILE"
  AIR_FILES+=("$AIR_FILE")
done

mkdir -p "$OUTPUT_DIR" "$DERIVED_FILE_DIR"
xcrun -sdk macosx metallib "${AIR_FILES[@]}" -o "$OUTPUT_METALLIB"
printf '%s' "$CURRENT_HASH" > "$HASH_FILE"

if [[ ! -s "$OUTPUT_METALLIB" ]]; then
  echo "error: MLX Metal library was not produced" >&2
  exit 1
fi

echo "Built MLX Metal library: $OUTPUT_METALLIB"
