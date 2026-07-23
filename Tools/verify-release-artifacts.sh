#!/bin/bash
set -euo pipefail

TARGET_PATH="${1:-}"
if [[ -z "$TARGET_PATH" ]]; then
    echo "Usage: $0 <path-to-app-bundle-xcarchive-or-zip>" >&2
    exit 64
fi
if [[ ! -e "$TARGET_PATH" ]]; then
    echo "Error: target does not exist: $TARGET_PATH" >&2
    exit 66
fi

WORK_DIR=""
cleanup() {
    if [[ -n "$WORK_DIR" ]]; then rm -rf "$WORK_DIR"; fi
}
trap cleanup EXIT

SCAN_ROOT="$TARGET_PATH"
if [[ -f "$TARGET_PATH" && "$TARGET_PATH" == *.zip ]]; then
    WORK_DIR="$(mktemp -d)"
    ditto -x -k "$TARGET_PATH" "$WORK_DIR"
    SCAN_ROOT="$WORK_DIR"
fi

FAILED=0
MACHO_COUNT=0
DISALLOWED_PATTERN='sherpa|onnx|kokoro'
WEIGHT_PATTERN='\.(onnx|ort|safetensors|gguf|pth|pt|ckpt)$'

echo "=== Verifying release artifact: $TARGET_PATH ==="
echo "[1/3] Checking every Mach-O slice"
while IFS= read -r -d '' file_path; do
    file_type="$(file -b "$file_path")"
    [[ "$file_type" == *"Mach-O"* ]] || continue
    MACHO_COUNT=$((MACHO_COUNT + 1))
    architectures="$(lipo -archs "$file_path" 2>/dev/null || true)"
    if [[ "$architectures" != "arm64" ]]; then
        echo "FAIL: $file_path has architectures '${architectures:-unknown}', expected exactly 'arm64'" >&2
        FAILED=1
    fi

done < <(find "$SCAN_ROOT" -type f -print0)
if [[ $MACHO_COUNT -eq 0 ]]; then
    echo "FAIL: no Mach-O executable code found" >&2
    FAILED=1
else
    echo "Checked $MACHO_COUNT Mach-O files"
fi

echo "[2/3] Checking linked libraries"
while IFS= read -r -d '' file_path; do
    file_type="$(file -b "$file_path")"
    [[ "$file_type" == *"Mach-O"* ]] || continue
    dependencies="$(otool -L "$file_path" 2>/dev/null || true)"
    if printf '%s\n' "$dependencies" | grep -Eiq "$DISALLOWED_PATTERN"; then
        echo "FAIL: removed runtime linked by $file_path" >&2
        printf '%s\n' "$dependencies" >&2
        FAILED=1
    fi
done < <(find "$SCAN_ROOT" -type f -print0)

echo "[3/3] Checking bundle paths and model weights"
while IFS= read -r -d '' entry; do
    relative="${entry#"$SCAN_ROOT"/}"
    if printf '%s\n' "$relative" | grep -Eiq "$DISALLOWED_PATTERN"; then
        echo "FAIL: removed runtime path found: $relative" >&2
        FAILED=1
    fi
    if [[ -f "$entry" ]] && printf '%s\n' "$relative" | grep -Eiq "$WEIGHT_PATTERN"; then
        echo "FAIL: model weight must not ship in the app/archive: $relative" >&2
        FAILED=1
    fi
done < <(find "$SCAN_ROOT" -mindepth 1 -print0)

if [[ $FAILED -ne 0 ]]; then
    echo "=== FAILURE: release artifact verification failed ===" >&2
    exit 1
fi

echo "=== SUCCESS: arm64-only and dependency-pure artifact ==="
