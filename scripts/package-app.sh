#!/bin/bash
# KD Player'ı dist/KDPlayer.app olarak paketler.
#
#   scripts/package-app.sh             → release, dist/KDPlayer.app
#   scripts/package-app.sh --debug     → debug derleme (hızlı, geliştirme için)
#   scripts/package-app.sh --run       → paketleyip açar
#   scripts/package-app.sh --install   → /Applications'a kopyalayıp açar
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
for arg in "$@"; do
    case "$arg" in
        --debug) CONFIG="debug" ;;
        --run) RUN=1 ;;
        --install) INSTALL=1 ;;
    esac
done
APP="dist/$EXECUTABLE.app"

scripts/fetch-vlckit.sh

echo "→ $CONFIG derleniyor…"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

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
    <key>KDRoomDatabaseURL</key>
    <string>$ROOM_URL</string>
    <key>KDRoomAPIKey</key>
    <string>$ROOM_KEY</string>
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

echo "✓ $APP"
if [[ $INSTALL -eq 1 ]]; then
    rm -rf "/Applications/$EXECUTABLE.app"
    cp -R "$APP" /Applications/
    open "/Applications/$EXECUTABLE.app"
elif [[ $RUN -eq 1 ]]; then
    open "$APP"
fi
