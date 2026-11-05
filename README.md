# KD Player

macOS için SwiftUI ile yazılan, VLC tabanlı ve her formatı oynatan video oynatıcı. Türkçe altyazıyı
kendiliğinden bulup senkronlar; arkadaşlarla aynı odada birlikte izletir.
Tasarım: *KD Player – Liquid Glass* canvas'ı · Davranış: *KD Player – Geliştirici Spesifikasyonu*.

## Derleme

```bash
scripts/fetch-vlckit.sh          # VLCKit 3.7.3'ü VideoLAN'dan Vendor/ altına indirir (bir kez, ~85 MB)
scripts/package-app.sh --debug --run   # dist/KDPlayer.app oluşturup açar
scripts/package-app.sh           # release paketi
scripts/test.sh                  # birim testleri
```

`swift build` tek başına da derler, ama VLCKit'in kurulum adı `@loader_path/../Frameworks` olduğu için
uygulamayı paket (`dist/KDPlayer.app`) olarak çalıştırın.

## Yapı

| Klasör | İçerik |
| --- | --- |
| `Design/` | Tokenlar (`Theme`, `Overlay`), cam yüzeyler, bileşenler (`KDButtonStyle`, `KDSegmented`, `KDSwitch`, `KDOptionRow`, `KDBadge`, `KDSlider`…), toast ve HUD, trafik ışıkları |
| `Player/` | `PlayerController` (VLCKit sarmalayıcısı), `PlayerSession` (ekran durumu, kısayollar, devam et, sonraki bölüm, PiP), oynatıcı ekranı, kontrol çubuğu, parça popover'ı, hata kartı |
| `Subtitles/` | SRT/ASS/VTT ayrıştırıcı, Türkçe kodlama çözücü, OpenSubtitles hash + istemci, `SubtitleService` (arama sırası, güven skoru, senkron), görünüm ve panel |
| `Home/`, `Settings/` | Başlangıç / ilk açılış, Ayarlar (Genel, Altyazı, Oda, Kısayollar) |
| `Data/` | SwiftData `WatchRecord`: konum, altyazı ve offset dosya hash'ine göre saklanır |
| `Room/` | `RoomBackend` (Firebase RTDB REST + canlı akış, Anonymous Auth), `RoomService` (oda durumu, olaylar, sohbet, altyazı paylaşımı), `PlayerSession+Room` (eşitleme, sapma düzeltme, buffering), oda ekranları |

## Durum

Çalışan: oynatma ve kontrol katmanı, kısayollar ve jestler, HUD'lar, ses/altyazı parça seçimi, altyazı
arama sırası (dosyanın içi → yanındaki dosya → OpenSubtitles hash → ad), Windows-1254/ISO-8859-9 düzeltme,
G/H gecikme, "Duy ve bas" (iki noktada FPS ölçeği), altyazı görünümü, kaldığın yerden devam, İzlemeye devam et,
sonraki bölüm, resim içinde resim (yüzen küçük pencere), hata kartı, açık/koyu tema ve vurgu rengi, Now Playing.

Birlikte izleme odası: Oda kur (kod + davet linki, kontrol modu, kilitli oda, altyazı paylaşımı), davetle katılma
(eşleşen dosyayı hash ile bulur), hazır kontrolü + 3 sn geri sayım, oynat/duraklat/sar/hız eşitleme, 2 sn'de bir
sapma düzeltme (< 150 ms dokunma, 150 ms – 2 sn hız ×0,97/×1,03, > 2 sn sar), biri takılınca herkes bekler,
yeniden bağlanma, sürüm uyuşmazlığı uyarısı, sohbet (zaman damgalı mesajlar), tepkiler, paylaşılan altyazı kartı.

Sonraki adımlar: otomatik senkron (VAD + çapraz korelasyon), scrubber küçük resim önizlemesi, Subdl/Podnapisi
kaynakları, Sparkle güncellemesi, Developer ID imzası + notarization, v2'de WebRTC data channel.

## Oda sunucusu

Kullanıcı hiçbir şey ayarlamaz: sunucu adresi paketleme sırasında uygulamanın içine gömülür ve "Oda kur"
doğrudan çalışır. Sunucu, Firebase Realtime Database'in ücretsiz (Spark) planıdır; kimlik doğrulaması yoktur,
güvenliği [firebase/database.rules.json](firebase/database.rules.json) sağlar (oda kodu biçimi, alan şeması,
boyut sınırları; oda başına en fazla 8 üyeyi uygulama uygular).

Geliştirici olarak bir kez:

```bash
scripts/setup-room-server.sh     # Google girişi → proje + veritabanı + kurallar → Config/room-server.json
scripts/package-app.sh           # adres Info.plist'e (KDRoomDatabaseURL) gömülür
```

`Config/room-server.json` yoksa paket yine derlenir ama birlikte izleme kapalı olur.

Firebase olmadan yerelde denemek için RTDB uyumlu geliştirme sunucusu:

```bash
node scripts/dev-room-server.mjs 9000
open -n --env KD_ROOM_SERVER=http://127.0.0.1:9000 --env KD_PROFILE=a dist/KDPlayer.app
open -n --env KD_ROOM_SERVER=http://127.0.0.1:9000 --env KD_PROFILE=b dist/KDPlayer.app
```

`KD_PROFILE` aynı Mac'teki iki kopyaya ayrı kimlik verir. Debug derlemede `KD_DEBUG_ROOM=create|join:KOD`,
`KD_DISPLAY_NAME`, `KD_DEBUG_ACTIONS=1` uçtan uca testi otomatikleştirir.

OpenSubtitles için Ayarlar › Altyazı'ya API anahtarı girilmeli (ya da `KD_OPENSUBTITLES_KEY` ortam değişkeni).
