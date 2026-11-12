#!/bin/bash
# Apple onayı (notarization) için notarytool kimliğini Anahtar Zinciri'ne bir kez kaydeder.
#
#   scripts/notary-setup.sh                 → Apple ID ile (uygulamaya özel parola sorar)
#
# Uygulamaya özel parola: account.apple.com › Giriş ve Güvenlik › Uygulamaya Özel Parolalar.
# Parola Anahtar Zinciri'nde "KDPlayer" profili olarak saklanır; depoya ya da betiklere yazılmaz.
# Sonra: scripts/release.sh (paketi otomatik onaylatır) ya da scripts/package-app.sh --dmg --notarize.
set -euo pipefail

PROFILE="${NOTARY_PROFILE:-KDPlayer}"
TEAM_ID="${TEAM_ID:-$(security find-identity -v -p codesigning | sed -nE 's/.*"Developer ID Application: [^"]*\(([A-Z0-9]{10})\)".*/\1/p' | head -1)}"
[[ -n "$TEAM_ID" ]] || { echo "✗ Developer ID Application sertifikası bulunamadı (Xcode › Settings › Accounts › Manage Certificates)" >&2; exit 1; }

read -r -p "Apple ID e-postası: " APPLE_ID
[[ -n "$APPLE_ID" ]] || exit 1
echo "Ekip: $TEAM_ID · notarytool şimdi uygulamaya özel parolayı soracak."
xcrun notarytool store-credentials "$PROFILE" --apple-id "$APPLE_ID" --team-id "$TEAM_ID"
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null && echo "✓ \"$PROFILE\" profili hazır"
