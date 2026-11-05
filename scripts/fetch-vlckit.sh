#!/bin/bash
# VLCKit'i (libVLC 3.x, LGPL) resmi VideoLAN sunucusundan indirip Vendor/VLCKit.xcframework olarak hazırlar.
# Framework dinamik bağlanır ve uygulama paketine gömülür (LGPL gereği). Depoya girmez (.gitignore).
#
#   scripts/fetch-vlckit.sh          → yoksa indirir
#   scripts/fetch-vlckit.sh --force  → yeniden indirir
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="3.7.3-319ed2c0-79128878"
URL="https://download.videolan.org/pub/cocoapods/prod/VLCKit-$VERSION.tar.xz"
OUT="Vendor/VLCKit.xcframework"

if [[ -d "$OUT" && "${1:-}" != "--force" ]]; then
    echo "✓ $OUT zaten var"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
echo "→ VLCKit $VERSION indiriliyor (~85 MB)…"
curl -fL --progress-bar "$URL" -o "$WORK/vlckit.tar.xz"
tar -xJf "$WORK/vlckit.tar.xz" -C "$WORK"

SRC="$(find "$WORK" -maxdepth 3 -name 'VLCKit.xcframework' -type d | head -1)"
rm -rf "$OUT"
mkdir -p Vendor
if [[ -n "$SRC" ]]; then
    cp -R "$SRC" "$OUT"
else
    FW="$(find "$WORK" -maxdepth 3 -name 'VLCKit.framework' -type d | head -1)"
    [[ -n "$FW" ]] || { echo "✗ Arşivde VLCKit bulunamadı" >&2; exit 1; }
    xcodebuild -create-xcframework -framework "$FW" -output "$OUT" >/dev/null
fi
# Lisans metni Hakkında penceresinde gösterilir.
find "$WORK" -maxdepth 3 -iname 'COPYING*' -exec cp {} Vendor/VLCKit-LICENSE.txt \; -quit || true
echo "✓ $OUT hazır"
