#!/bin/bash
# Birlikte izleme sunucusunu bir kez kurar: Firebase projesi + Realtime Database (Spark, ücretsiz) + kurallar,
# sonra adresi Config/room-server.json'a yazar. scripts/package-app.sh bu adresi uygulamaya gömer;
# kullanıcılar Firebase'i hiç görmez. Yalnızca geliştirici (uygulamayı dağıtan) bir kez çalıştırır.
#
#   scripts/setup-room-server.sh                 → yeni proje (kdplayer-rooms-xxxx), europe-west1
#   scripts/setup-room-server.sh mevcut-proje-id → var olan projeyi kullanır
#   REGION=us-central1 scripts/setup-room-server.sh
#
# Gerekenler: Node (npx) ve bir Google hesabı (ilk çalıştırmada tarayıcıda giriş istenir).
set -euo pipefail
cd "$(dirname "$0")/.."

REGION="${REGION:-europe-west1}"
FB=(npx --yes firebase-tools)

echo "→ Firebase oturumu kontrol ediliyor…"
if ! "${FB[@]}" login:list 2>/dev/null | grep -q "@"; then
    "${FB[@]}" login
fi

PROJECT="${1:-}"
if [[ -z "$PROJECT" ]]; then
    PROJECT="kdplayer-rooms-$(openssl rand -hex 3)"
    echo "→ Proje oluşturuluyor: $PROJECT"
    "${FB[@]}" projects:create "$PROJECT" --display-name "KD Player Rooms"
else
    echo "→ Mevcut proje kullanılıyor: $PROJECT"
fi

INSTANCE="$PROJECT-default-rtdb"
if [[ "$REGION" == "us-central1" ]]; then
    URL="https://$INSTANCE.firebaseio.com"
else
    URL="https://$INSTANCE.$REGION.firebasedatabase.app"
fi

# Veritabanı varsa kilitli modda 401, yoksa 404 döner.
STATUS="$(curl -s -o /dev/null -w "%{http_code}" "$URL/.json")"
if [[ "$STATUS" == "404" ]]; then
    echo "→ Realtime Database oluşturuluyor ($REGION)…"
    "${FB[@]}" database:instances:create "$INSTANCE" --location "$REGION" --project "$PROJECT" \
        || { echo "✗ Oluşturulamadı: Firebase konsolu › Realtime Database › Create database ($REGION), sonra betiği tekrar çalıştır." >&2; exit 1; }
else
    echo "→ Realtime Database zaten var ($URL)"
fi

echo "→ Güvenlik kuralları yükleniyor…"
(cd firebase && "${FB[@]}" deploy --only database --project "$PROJECT" --non-interactive)

echo "→ Bağlantı deneniyor…"
NOW="$(curl -fsS -X PUT "$URL/clock/setup-check.json" -d '{".sv":"timestamp"}')"
curl -fsS -X DELETE "$URL/clock/setup-check.json" >/dev/null
[[ "$NOW" =~ ^[0-9]+$ ]] || { echo "✗ Veritabanına yazılamadı: $NOW" >&2; exit 1; }

python3 - "$URL" "$PROJECT" <<'PY'
import json, sys
json.dump({"databaseURL": sys.argv[1], "project": sys.argv[2]}, open("Config/room-server.json", "w"), indent=2)
PY
echo "✓ Config/room-server.json yazıldı ($URL)"
echo "  Şimdi: scripts/package-app.sh  → paketlenen uygulamada Oda kur doğrudan çalışır."
