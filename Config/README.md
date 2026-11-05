# Config

`room-server.json` birlikte izleme odasının sunucu adresidir; `scripts/package-app.sh` bunu uygulamanın
Info.plist'ine gömer, kullanıcı hiçbir şey ayarlamaz. Bir kez `scripts/setup-room-server.sh` ile oluşturulur.
Adres gizli değildir (her istemci zaten görür); güvenliği firebase/database.rules.json sağlar.
