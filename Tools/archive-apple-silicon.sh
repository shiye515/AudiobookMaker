#!/bin/bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
ARCHIVE_PATH="$ROOT/build/AudiobookMaker-AppleSilicon.xcarchive"
if [[ $# -gt 0 ]]; then
    ARCHIVE_PATH="$1"
    shift
fi
APP_PATH="$ARCHIVE_PATH/Products/Applications/AudiobookMaker.app"

rm -rf "$ARCHIVE_PATH"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
xcodebuild archive \
    -project "$ROOT/AudiobookMaker.xcodeproj" \
    -scheme AudiobookMaker \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE_PATH" \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=YES \
    "$@"

"$ROOT/Tools/verify-release-artifacts.sh" "$ARCHIVE_PATH"

if [[ "${SKIP_SIGNATURE_CHECK:-0}" != "1" ]]; then
    codesign --verify --deep --strict --verbose=2 "$APP_PATH"
fi

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    ZIP_PATH="${ARCHIVE_PATH%.xcarchive}.zip"
    rm -f "$ZIP_PATH"
    ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
    xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP_PATH"
    xcrun stapler validate "$APP_PATH"
fi

echo "Release archive ready: $ARCHIVE_PATH"
