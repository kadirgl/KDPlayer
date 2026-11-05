#!/bin/bash
# Güncelleme imza anahtarını oluşturur ve macOS Anahtar Zinciri'ne koyar (bir kez çalıştırılır).
# Açık anahtar scripts/update-public-key.txt'e yazılır ve depoya eklenir; uygulama paketlenirken
# Info.plist'e girer. Gizli anahtar yalnızca bu Mac'in Anahtar Zinciri'nde durur: kaybolursa
# kullanıcılara uygulama içinden güncelleme gönderilemez, mutlaka yedekleyin (scripts/update-key.sh --export).
set -euo pipefail
cd "$(dirname "$0")/.."

SERVICE="KDPlayer update signing key"

if [[ "${1:-}" == "--export" ]]; then
    security find-generic-password -a "$USER" -s "$SERVICE" -w
    exit 0
fi

if security find-generic-password -a "$USER" -s "$SERVICE" >/dev/null 2>&1; then
    echo "Anahtar zaten var. Açık anahtar:"
    security find-generic-password -a "$USER" -s "$SERVICE" -w | swift scripts/update-signing.swift public
    exit 0
fi

PUBLIC_FILE="$(mktemp)"
trap 'rm -f "$PUBLIC_FILE"' EXIT
PRIVATE="$(swift scripts/update-signing.swift generate 2>"$PUBLIC_FILE")"
security add-generic-password -a "$USER" -s "$SERVICE" -w "$PRIVATE" -T /usr/bin/security
unset PRIVATE
cp "$PUBLIC_FILE" scripts/update-public-key.txt
echo "✓ Gizli anahtar Anahtar Zinciri'ne kaydedildi (\"$SERVICE\")."
echo "✓ Açık anahtar: $(cat scripts/update-public-key.txt)  → scripts/update-public-key.txt"
