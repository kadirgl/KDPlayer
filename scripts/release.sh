#!/bin/bash
# Yeni sürümü GitHub Releases'te yayımlar; kurulu uygulamalar bunu kendisi bulup kurar
# (Ayarlar › Genel › Uygulama güncellemesi, AppUpdater).
#
#   scripts/release.sh 0.2.0               → notlar son sürümden beri commit başlıklarından
#   scripts/release.sh 0.2.0 notlar.md     → notlar dosyadan
#
# Adımlar: paketler (evrensel .app + zip + dmg), zip'i Anahtar Zinciri'ndeki gizli anahtarla imzalar, imzayı
# denetler, v0.2.0 etiketini ve main'i gönderir, zip + imza + dmg ile GitHub sürümünü oluşturur.
# Gerekenler: gh (giriş yapılmış), temiz çalışma ağacı, scripts/update-key.sh ile oluşturulmuş anahtar.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
NOTES_FILE="${2:-}"
SERVICE="KDPlayer update signing key"
TAG="v$VERSION"

fail() { echo "✗ $*" >&2; exit 1; }

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Kullanım: scripts/release.sh 0.2.0 [notlar.md]"
command -v gh >/dev/null || fail "gh yok (brew install gh)"
gh auth status >/dev/null 2>&1 || fail "gh'ye giriş yapılmamış (gh auth login)"
[[ -z "$(git status --porcelain)" ]] || fail "Çalışma ağacında commit'lenmemiş değişiklik var"
[[ "$(git branch --show-current)" == "main" ]] || fail "main dalında değilsiniz"
git remote get-url origin >/dev/null 2>&1 || fail "origin (GitHub deposu) yok"
[[ -f scripts/update-public-key.txt ]] || fail "Açık anahtar yok (scripts/update-key.sh)"
[[ -f Config/room-server.json ]] || fail "Config/room-server.json yok: birlikte izleme kapalı paketlenirdi"
[[ -s Config/opensubtitles.key || -n "${OPENSUBTITLES_API_KEY:-}" ]] || fail "Config/opensubtitles.key yok: internetten altyazı bulma kapalı paketlenirdi"
[[ -s Config/subdl.key || -n "${SUBDL_API_KEY:-}" ]] || fail "Config/subdl.key yok: Subdl kapalı paketlenirdi"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && fail "$TAG etiketi zaten var"

LATEST="$(gh release view --json tagName -q .tagName 2>/dev/null || true)"
if [[ -n "$LATEST" ]]; then
    NEWEST="$(printf '%s\n%s\n' "${LATEST#v}" "$VERSION" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
    [[ "$NEWEST" == "$VERSION" && "${LATEST#v}" != "$VERSION" ]] || fail "$VERSION, yayımlanan son sürümden ($LATEST) yeni değil"
fi

PRIVATE_KEY="$(security find-generic-password -a "$USER" -s "$SERVICE" -w 2>/dev/null)" \
    || fail "Gizli anahtar Anahtar Zinciri'nde yok (scripts/update-key.sh)"
PUBLIC_KEY="$(cat scripts/update-public-key.txt)"
[[ "$(printf '%s' "$PRIVATE_KEY" | swift scripts/update-signing.swift public)" == "$PUBLIC_KEY" ]] \
    || fail "Anahtar Zinciri'ndeki gizli anahtar scripts/update-public-key.txt ile eşleşmiyor"

VERSION="$VERSION" scripts/package-app.sh --dmg
ASSET="dist/KDPlayer-$VERSION.zip"
DMG="dist/KDPlayer-$VERSION.dmg"
[[ -f "$ASSET" && -f "$DMG" ]] || fail "Paket oluşmadı"

echo "→ İmzalanıyor…"
printf '%s' "$PRIVATE_KEY" | swift scripts/update-signing.swift sign "$ASSET" > "$ASSET.sig"
unset PRIVATE_KEY
swift scripts/update-signing.swift verify "$ASSET" "$ASSET.sig" "$PUBLIC_KEY"

NOTES="$(mktemp)"
trap 'rm -f "$NOTES"' EXIT
if [[ -n "$NOTES_FILE" ]]; then
    cat "$NOTES_FILE" > "$NOTES"
else
    RANGE="${LATEST:+$LATEST..}HEAD"
    { echo "## Değişiklikler"; echo; git log --no-merges --format='- %s' "$RANGE"; } > "$NOTES"
fi
cat >> "$NOTES" <<NOTES

---
**Kurulum:** \`KDPlayer-$VERSION.dmg\` dosyasını açıp **KD Player**'ı **Uygulamalar** klasörüne sürükleyin.
İlk açılışta macOS "geliştirici doğrulanamadı" derse: Sistem Ayarları › Gizlilik ve Güvenlik › **Yine de Aç**.
Kurulu uygulama yeni sürümleri kendisi bulur (Ayarlar › Genel › Uygulama güncellemesi).
Apple Silicon ve Intel, macOS 14 Sonoma ve sonrası.
NOTES

echo "→ $TAG gönderiliyor…"
git tag -a "$TAG" -m "KD Player $VERSION"
git push origin main "$TAG"
gh release create "$TAG" "$ASSET" "$ASSET.sig" "$DMG" --title "KD Player $VERSION" --notes-file "$NOTES"
echo "✓ Yayımlandı: $(gh release view "$TAG" --json url -q .url)"
