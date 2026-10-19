#!/usr/bin/env bash
# Build Cuewire and assemble a signed .app bundle in dist/.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="${1:-release}"
swift build -c "$CONFIG"

APP="$ROOT/dist/Cuewire.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp ".build/$CONFIG/FLXBridge" "$APP/Contents/MacOS/FLXBridge"
cp Packaging/Info.plist "$APP/Contents/Info.plist"

ICONSET="$ROOT/.build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
swift scripts/make-icon.swift "$ROOT/.build/icon-1024.png" >/dev/null
for spec in "16 16" "32 16" "32 32" "64 32" "128 128" "256 128" "256 256" "512 256" "512 512" "1024 512"; do
    set -- $spec
    size=$1
    base=$2
    sips -z "$size" "$size" "$ROOT/.build/icon-1024.png" \
        --out "$ICONSET/icon_${base}x${base}@$((size / base))x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "warning: ad-hoc codesign skipped"
echo "Built $APP"
