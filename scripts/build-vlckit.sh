#!/bin/bash
# VLCKit'i (macOS, arm64 + x86_64) kaynaktan TrueHD/MLP çözücüsü AÇIK olarak derleyip Vendor/VLCKit.xcframework'e koyar.
#
# Neden: VideoLAN'ın hazır VLCKit paketi, VLCKit'in kendi yaması (libvlc/patches/0003-Enable-System-DL.patch)
# yüzünden FFmpeg'i --disable-decoder=mlp --disable-demuxer=mlp --disable-parser=mlp ile derliyor.
# FFmpeg'de truehd çözücüsü mlp parser'ına bağlı olduğu için TrueHD (Blu-ray 7.1 / Atmos) da kapanıyor;
# VLC günlüğü "codec not found (TrueHD Audio)" diyor. Bu betik aynı sürümü o üç satır olmadan derler.
#
#   scripts/build-vlckit.sh            → derler (ilk sefer ~20-30 dk, 10 çekirdekli Apple Silicon; sonra kaldığı yerden)
#   scripts/build-vlckit.sh --clean    → kaynak dizinini silip sıfırdan derler
#
# Kaynak/ara çıktı: $KD_VLCKIT_BUILD_DIR (varsayılan ~/Library/Caches/KDPlayer/vlckit-build, ~11 GB).
# Gerekenler: Xcode (macOS SDK), git, curl. Araçlar (autoconf, cmake, meson, nasm…) VLC'nin extras/tools'u ile kurulur.
set -euo pipefail
cd "$(dirname "$0")/.."

# 3.7.5: libVLC 3.0.24 + yeni Xcode/SDK derleme düzeltmeleri. Genel API (Headers/, Sources/) hazır paketteki
# 3.7.3 ile birebir aynı; 3.7.5'in macOS hazır paketi yayımlanmadığı için fetch-vlckit.sh 3.7.3'te kalır.
VLCKIT_TAG="3.7.5"
VLCKIT_GIT="https://code.videolan.org/videolan/VLCKit.git"
WORK="${KD_VLCKIT_BUILD_DIR:-$HOME/Library/Caches/KDPlayer/vlckit-build}"
SRC="$WORK/VLCKit-$VLCKIT_TAG"
OUT="Vendor/VLCKit.xcframework"
MARKER="Vendor/VLCKit.source"

[[ "${1:-}" == "--clean" ]] && rm -rf "$SRC"
mkdir -p "$WORK"

if [[ ! -d "$SRC/.git" ]]; then
    echo "→ VLCKit $VLCKIT_TAG kaynağı indiriliyor…"
    git clone -q --depth 1 --branch "$VLCKIT_TAG" "$VLCKIT_GIT" "$SRC"
fi

# 1) VLCKit'in FFmpeg yamasından mlp/TrueHD'yi kapatan üç satırı çıkar.
PATCH="$SRC/libvlc/patches/0003-Enable-System-DL.patch"
if grep -q -- '--disable-decoder=mlp' "$PATCH"; then
    echo "→ FFmpeg yapılandırmasında TrueHD/MLP açılıyor ($(basename "$PATCH"))"
    # rules.mak'e dokunan hunk yalnızca bu üç satırı ekliyor; hunk'ı bütünüyle çıkar.
    perl -0pi -e 's/\@\@ -33,6 \+33,9 \@\@.*?(?=\@\@ )//s' "$PATCH"
    if grep -q -- '=mlp' "$PATCH"; then echo "✗ Yama değiştirilemedi: $PATCH" >&2; exit 1; fi
fi
# Xcode 26+ macOS 12.0'dan eski hedefi kabul etmiyor (proje 10.9 diyor; hazır 3.7.3 paketi minos 11.0).
# Uygulama macOS 14 hedefliyor; framework'ü desteklenen en eski sürüm olan 12.0'a çek.
sed -i '' 's/MACOSX_DEPLOYMENT_TARGET = 10\.9;/MACOSX_DEPLOYMENT_TARGET = 12.0;/' "$SRC/VLCKit.xcodeproj/project.pbxproj"

VLC="$SRC/libvlc/vlc"
if [[ ! -d "$VLC/.git" ]]; then
    # buildMobileVLCKit.sh'in yaptığı gibi: libVLC 3.0.x'i test edilen kayda alıp VLCKit yamalarını uygula.
    HASH="$(sed -nE 's/^TESTEDHASH="([0-9a-f]+)".*/\1/p' "$SRC/buildMobileVLCKit.sh")"
    echo "→ libVLC ($HASH) indirilip VLCKit yamaları uygulanıyor…"
    git clone -q --branch 3.0.x --single-branch https://code.videolan.org/videolan/vlc.git "$VLC"
    git -C "$VLC" checkout -q -B localBranch "$HASH"
    git -C "$VLC" -c user.name="KD Player build" -c user.email="build@localhost" am -q "$SRC"/libvlc/patches/*.patch
elif grep -q -- '--disable-decoder=mlp' "$VLC/contrib/src/ffmpeg/rules.mak"; then
    # Yamadan önce oluşmuş eski bir kopya: satırları burada sil, ffmpeg contrib'i yeniden derlensin.
    echo "→ Eski vlc kopyası mlp'yi kapatıyor; ffmpeg contrib'i yeniden derlenecek"
    sed -i '' -e '/--disable-decoder=mlp/d' -e '/--disable-demuxer=mlp/d' -e '/--disable-parser=mlp/d' "$VLC/contrib/src/ffmpeg/rules.mak"
    find "$VLC/contrib" -maxdepth 2 \( -name '.ffmpeg' -o -name 'ffmpeg' \) -path '*MacOSX*' -exec rm -rf {} +
fi
grep -q -- '=mlp' "$VLC/contrib/src/ffmpeg/rules.mak" && { echo "✗ rules.mak hâlâ mlp'yi kapatıyor" >&2; exit 1; }

# 2) GNU Make 4.x: macOS'taki make 3.81, VLC araçlarındaki ninja'nın (jobserver istemcisi) paylaşılan iş borusunu
#    bloklamasız yapmasıyla "read jobs pipe: Resource temporarily unavailable" deyip düşüyor. buildMobileVLCKit.sh
#    PATH'e önce extras/tools/build/bin'i koyduğu için make oraya kurulur.
TOOLS_BIN="$VLC/extras/tools/build/bin"
if ! "$TOOLS_BIN/make" --version 2>/dev/null | grep -q 'GNU Make 4'; then
    MAKE_VER="4.4.1"
    MAKE_SHA="dd16fb1d67bfab79a72f5e8390735c49e3e8e70b4945a15ab1f81ddb78658fb3"
    echo "→ GNU Make $MAKE_VER derleniyor…"
    rm -rf "$WORK/make-$MAKE_VER"
    curl -fsSL "https://ftp.gnu.org/gnu/make/make-$MAKE_VER.tar.gz" -o "$WORK/make.tar.gz"
    echo "$MAKE_SHA  $WORK/make.tar.gz" | shasum -a 256 -c - >/dev/null || { echo "✗ make arşivinin özeti tutmuyor" >&2; exit 1; }
    tar -xzf "$WORK/make.tar.gz" -C "$WORK"
    ( cd "$WORK/make-$MAKE_VER" && ./configure -q --disable-nls && ./build.sh ) > "$WORK/make-build.log" 2>&1
    mkdir -p "$TOOLS_BIN"
    cp "$WORK/make-$MAKE_VER/make" "$TOOLS_BIN/make"
fi

# 3) Derle: buildMobileVLCKit.sh -x → araçlar, contrib'ler ve libVLC (x86_64 + aarch64), sonra VLCKit.xcframework.
#    -n: vlc kopyası yukarıda hazırlandı, betik onu sıfırlayıp yeniden yamalamasın (kaldığı yerden devam eder).
echo "→ VLCKit $VLCKIT_TAG derleniyor; ayrıntı: $WORK/build.log"
( cd "$SRC" && MAKE_JOBS="${MAKE_JOBS:-$(sysctl -n hw.ncpu)}" ./buildMobileVLCKit.sh -x -n -v ) > "$WORK/build.log" 2>&1 || {
    echo "✗ Derleme başarısız, günlüğün sonu:" >&2; tail -40 "$WORK/build.log" >&2; exit 1; }

BUILT="$SRC/build/VLCKit.xcframework"
[[ -d "$BUILT" ]] || { echo "✗ $BUILT oluşmadı" >&2; exit 1; }
BIN="$BUILT/macos-arm64_x86_64/VLCKit.framework/Versions/A/VLCKit"
for arch in arm64 x86_64; do
    # grep -q erken çıkınca nm SIGPIPE alır ve pipefail boru hattını başarısız sayar: tüm çıktıyı say.
    [[ "$(nm -gU -arch "$arch" "$BIN" | grep -c '_ff_truehd_decoder$')" -ge 1 ]] || { echo "✗ $arch diliminde ff_truehd_decoder yok" >&2; exit 1; }
done

rm -rf "$OUT"
mkdir -p Vendor
cp -R "$BUILT" "$OUT"
cp "$SRC/COPYING" Vendor/VLCKit-LICENSE.txt
echo "source $VLCKIT_TAG truehd" > "$MARKER"
echo "✓ $OUT hazır (VLCKit $VLCKIT_TAG, TrueHD/MLP açık, $(du -sh "$OUT" | cut -f1))"
