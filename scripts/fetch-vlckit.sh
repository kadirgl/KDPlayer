#!/bin/bash
# VLCKit'i (libVLC 3.x, LGPL) Vendor/VLCKit.xcframework olarak hazırlar.
# Framework dinamik bağlanır ve uygulama paketine gömülür (LGPL gereği). Depoya girmez (.gitignore).
#
#   scripts/fetch-vlckit.sh          → yoksa VideoLAN'ın hazır paketini indirir
#   scripts/fetch-vlckit.sh --force  → hazır paketi yeniden indirir (kaynaktan derleneni ezer)
#   KD_VLCKIT=source scripts/fetch-vlckit.sh → yoksa scripts/build-vlckit.sh ile kaynaktan derler
#
# Hazır paket TrueHD/MLP çözücüsü olmadan derlenmiştir (Blu-ray 7.1 / Atmos parçaları sessiz kalır, uygulama
# bunları "çalınamıyor" diye işaretler). TrueHD'li paket için: scripts/build-vlckit.sh (bir kez, ~20-30 dk).
# Hangi paketin kurulu olduğu Vendor/VLCKit.source'ta yazar.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="3.7.3-319ed2c0-79128878"   # macOS için son hazır paket (3.7.5 yalnızca iOS için yayımlandı; API aynı)
URL="https://download.videolan.org/pub/cocoapods/prod/VLCKit-$VERSION.tar.xz"
OUT="Vendor/VLCKit.xcframework"
MARKER="Vendor/VLCKit.source"

if [[ -d "$OUT" && "${1:-}" != "--force" ]]; then
    echo "✓ $OUT zaten var ($(cat "$MARKER" 2>/dev/null || echo "kaynağı bilinmiyor"))"
    exit 0
fi
if [[ "${KD_VLCKIT:-}" == "source" && "${1:-}" != "--force" ]]; then
    exec scripts/build-vlckit.sh
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
echo "official ${VERSION%%-*}" > "$MARKER"
echo "✓ $OUT hazır (hazır paket, TrueHD yok — TrueHD için scripts/build-vlckit.sh)"
