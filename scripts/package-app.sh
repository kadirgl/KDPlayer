#!/bin/bash
# KD Player'ı dist/KDPlayer.app olarak paketler.
#
#   scripts/package-app.sh             → release, dist/KDPlayer.app
#   scripts/package-app.sh --debug     → debug derleme (hızlı, geliştirme için)
#   scripts/package-app.sh --run       → paketleyip açar
#   scripts/package-app.sh --install   → /Applications'a kopyalayıp açar
#   scripts/package-app.sh --dmg       → ayrıca dist/KDPlayer-<sürüm>.dmg (Uygulamalar kısayollu)
#   scripts/package-app.sh --profile   → optimize + test/ölçüm kancaları (performans ölçümü için)
#
# Release derlemesi evrenseldir (Apple Silicon + Intel); --debug yalnızca bu Mac'in mimarisi.
# Sürüm: VERSION=0.2.0 scripts/package-app.sh --dmg
#
# VLCKit.framework Contents/Frameworks altına gömülür (LGPL: dinamik bağlama).
# İmza yerel (ad-hoc). Dağıtım için Developer ID + notarization gerekir (spesifikasyon › Dağıtım).
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="KD Player"
EXECUTABLE="KDPlayer"
BUNDLE_ID="com.kadirgul.KDPlayer"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
CONFIG="release"
RUN=0
INSTALL=0
DMG=0
PROFILE=0
for arg in "$@"; do
    case "$arg" in
        --debug) CONFIG="debug" ;;
        --dmg) DMG=1 ;;
        --profile) CONFIG="release"; PROFILE=1 ;;
        --run) RUN=1 ;;
        --install) INSTALL=1 ;;
    esac
done
APP="dist/$EXECUTABLE.app"

scripts/fetch-vlckit.sh
# Hazır VLCKit paketinde TrueHD/MLP çözücüsü yok (Blu-ray 7.1 / Atmos sesi çalınamaz).
if ! grep -q truehd Vendor/VLCKit.source 2>/dev/null; then
    echo "⚠ VLCKit TrueHD'siz (hazır paket): TrueHD parçaları çalınamaz. Kaynaktan derlemek için scripts/build-vlckit.sh"
fi

ARCH_FLAGS=()
# --profile: optimize edilmiş ama ölçüm/test kancaları açık (yalnızca bu Mac'in mimarisi, dağıtılmaz).
if [[ $PROFILE -eq 1 ]]; then
    ARCH_FLAGS=(-Xswiftc -DDEBUG)
elif [[ "$CONFIG" == "release" ]]; then
    ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi
echo "→ $CONFIG derleniyor…"
swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

echo "→ $APP oluşturuluyor…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/$EXECUTABLE" "$APP/Contents/MacOS/"
cp -R "Vendor/VLCKit.xcframework/macos-arm64_x86_64/VLCKit.framework" "$APP/Contents/Frameworks/"
[[ -f Vendor/VLCKit-LICENSE.txt ]] && cp Vendor/VLCKit-LICENSE.txt "$APP/Contents/Resources/"

ICON_WORK="$(mktemp -d)"
trap 'rm -rf "$ICON_WORK"' EXIT
swift scripts/render-icon.swift "$ICON_WORK/AppIcon.iconset"
iconutil -c icns "$ICON_WORK/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

# Birlikte izleme sunucusu: Config/room-server.json (scripts/setup-room-server.sh oluşturur).
ROOM_URL=""
ROOM_KEY=""
if [[ -f Config/room-server.json ]]; then
    ROOM_URL="$(python3 -c 'import json;print(json.load(open("Config/room-server.json")).get("databaseURL",""))')"
    ROOM_KEY="$(python3 -c 'import json;print(json.load(open("Config/room-server.json")).get("apiKey",""))')"
else
    echo "⚠ Config/room-server.json yok: bu pakette birlikte izleme kapalı olur (scripts/setup-room-server.sh)"
fi

# OpenSubtitles API anahtarı: Config/opensubtitles.key (depoya girmez) ya da OPENSUBTITLES_API_KEY.
OPENSUBTITLES_KEY="${OPENSUBTITLES_API_KEY:-}"
if [[ -z "$OPENSUBTITLES_KEY" && -f Config/opensubtitles.key ]]; then
    OPENSUBTITLES_KEY="$(tr -d '[:space:]' < Config/opensubtitles.key)"
fi
if [[ -z "$OPENSUBTITLES_KEY" ]]; then
    echo "⚠ OpenSubtitles anahtarı yok (Config/opensubtitles.key): internetten altyazı bulma kapalı paketlenir"
fi

# Subdl API anahtarı (ikinci altyazı kaynağı): Config/subdl.key (depoya girmez) ya da SUBDL_API_KEY. İsteğe bağlı.
SUBDL_KEY="${SUBDL_API_KEY:-}"
if [[ -z "$SUBDL_KEY" && -f Config/subdl.key ]]; then
    SUBDL_KEY="$(tr -d '[:space:]' < Config/subdl.key)"
fi
[[ -n "$SUBDL_KEY" ]] || echo "ℹ Subdl anahtarı yok (Config/subdl.key): Subdl yalnızca kullanıcı kendi anahtarını girerse çalışır"

# Uygulama içi güncelleme (AppUpdater): GitHub deposu origin'den, imzayı doğrulayan açık anahtar scripts/update-public-key.txt'ten.
UPDATE_REPOSITORY="${UPDATE_REPOSITORY:-$(git remote get-url origin 2>/dev/null | sed -nE 's#^(https://|git@)github\.com[:/]([^/]+/[^/.]+)(\.git)?$#\2#p' || true)}"
UPDATE_PUBLIC_KEY="$(cat scripts/update-public-key.txt 2>/dev/null || true)"
[[ -n "$UPDATE_REPOSITORY" && -n "$UPDATE_PUBLIC_KEY" ]] || echo "⚠ GitHub deposu ya da güncelleme anahtarı yok: bu paket kendini güncelleyemez"

VIDEO_EXTS="mkv mp4 m4v mov avi wmv flv webm ts m2ts mts mpg mpeg vob ogv 3gp divx rmvb asf"
EXT_XML=""
for ext in $VIDEO_EXTS; do EXT_XML+="                <string>$ext</string>"$'\n'; done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$NAME</string>
    <key>CFBundleExecutable</key>
    <string>$EXECUTABLE</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>tr</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.video</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>KDUpdateRepository</key>
    <string>$UPDATE_REPOSITORY</string>
    <key>KDUpdatePublicKey</key>
    <string>$UPDATE_PUBLIC_KEY</string>
    <key>KDRoomDatabaseURL</key>
    <string>$ROOM_URL</string>
    <key>KDRoomAPIKey</key>
    <string>$ROOM_KEY</string>
    <key>OpenSubtitlesAPIKey</key>
    <string>$OPENSUBTITLES_KEY</string>
    <key>SubdlAPIKey</key>
    <string>$SUBDL_KEY</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>KD Player davet linki</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>kdplayer</string>
            </array>
        </dict>
    </array>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Video</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.movie</string>
                <string>public.video</string>
                <string>public.audiovisual-content</string>
            </array>
            <key>CFBundleTypeExtensions</key>
            <array>
$EXT_XML            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Altyazı</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>None</string>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>srt</string>
                <string>ass</string>
                <string>ssa</string>
                <string>vtt</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

echo "→ İmzalanıyor (ad-hoc)…"
codesign --force --sign - "$APP/Contents/Frameworks/VLCKit.framework"
codesign --force --sign - "$APP"

echo "✓ $APP ($(lipo -archs "$APP/Contents/MacOS/$EXECUTABLE"))"

if [[ $DMG -eq 1 ]]; then
    # Güncelleyicinin indirdiği paket (imzası release.sh'de atılır).
    ZIP_PATH="dist/$EXECUTABLE-$VERSION.zip"
    rm -f "$ZIP_PATH"
    ditto -c -k --keepParent "$APP" "$ZIP_PATH"
    echo "✓ $ZIP_PATH ($(du -h "$ZIP_PATH" | cut -f1))"
    DMG_PATH="dist/$EXECUTABLE-$VERSION.dmg"
    STAGE="$(mktemp -d)"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    rm -f "$DMG_PATH"
    hdiutil create -quiet -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG_PATH"
    rm -rf "$STAGE"
    echo "✓ $DMG_PATH ($(du -h "$DMG_PATH" | cut -f1))"
fi
if [[ $INSTALL -eq 1 ]]; then
    rm -rf "/Applications/$EXECUTABLE.app"
    cp -R "$APP" /Applications/
    open "/Applications/$EXECUTABLE.app"
elif [[ $RUN -eq 1 ]]; then
    open "$APP"
fi
