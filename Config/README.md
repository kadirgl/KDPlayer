# Config

`room-server.json` birlikte izleme odasının sunucu adresidir; `scripts/package-app.sh` bunu uygulamanın
Info.plist'ine gömer, kullanıcı hiçbir şey ayarlamaz. Bir kez `scripts/setup-room-server.sh` ile oluşturulur.
Adres gizli değildir (her istemci zaten görür); güvenliği firebase/database.rules.json sağlar.

`opensubtitles.key` OpenSubtitles API anahtarıdır (opensubtitles.com › API consumers › KDPlayer). Depo herkese açık
olduğu için **git'e girmez** (.gitignore); `scripts/package-app.sh` paketleme sırasında Info.plist'e
(`OpenSubtitlesAPIKey`) gömer, `scripts/release.sh` dosya yoksa yayını durdurur. Yeni bir makinede tek satır olarak
oluşturun ya da `OPENSUBTITLES_API_KEY` ortam değişkenini verin. Kullanıcı Ayarlar › Altyazı'dan kendi anahtarını
girerse o önceliklidir.

`subdl.key` Subdl API anahtarıdır (subdl.com › Hesap › API; ücretsiz, günde 2.000 arama). Aynı şekilde git'e girmez ve
Info.plist'e (`SubdlAPIKey`) gömülür. İsteğe bağlıdır: yoksa Subdl yalnızca kullanıcı kendi anahtarını girerse çalışır.
