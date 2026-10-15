#!/bin/bash
# Build a relocatable macOS app. CONFIGURATION=release for distribution.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CONFIGURATION="${CONFIGURATION:-debug}"
case "$CONFIGURATION" in debug|release) ;; *) echo 'CONFIGURATION must be debug or release' >&2; exit 2 ;; esac
VERSION="${APP_VERSION:-1.1}"
BUILD_NUMBER="${APP_BUILD_NUMBER:-1}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo 'APP_VERSION must be numeric major.minor[.patch]; APP_BUILD_NUMBER must be numeric' >&2
  exit 2
fi
swift build -c "$CONFIGURATION" --product Ytb2ZHApp
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"
APP="$ROOT/.build/Ytb2ZH.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN_DIR/Ytb2ZHApp" "$APP/Contents/MacOS/"
ditto "$BIN_DIR/whisper.framework" "$APP/Contents/Frameworks/whisper.framework"
for resource in "$BIN_DIR"/*.bundle "$ROOT"/Support/*.lproj; do
  [[ ! -d "$resource" ]] || ditto "$resource" "$APP/Contents/Resources/$(basename "$resource")"
done
if [[ -f "$ROOT/Assets/AppIcon.icns" ]]; then cp "$ROOT/Assets/AppIcon.icns" "$APP/Contents/Resources/"; fi
cp "$ROOT/LICENSE" "$ROOT/THIRD-PARTY-NOTICES.md" "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Ytb2ZHApp</string>
<key>CFBundleIdentifier</key><string>com.ytb2zh.app</string>
<key>CFBundleName</key><string>ytb2zh</string>
<key>CFBundleDisplayName</key><string>ytb2zh 实时译配</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
<key>CFBundleLocalizations</key><array><string>zh-Hans</string><string>en</string></array>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict></plist>
PLIST
# SwiftPM's executable-relative rpath does not search Contents/Frameworks.
install_name_tool -add_rpath '@executable_path/../Frameworks' "$APP/Contents/MacOS/Ytb2ZHApp"
# Re-sign after editing Mach-O; no certificate or notarization credentials required.
codesign --force --sign - --timestamp=none "$APP/Contents/Frameworks/whisper.framework"
codesign --force --sign - --timestamp=none "$APP"
plutil -lint "$APP/Contents/Info.plist"
codesign --verify --deep --strict "$APP"
test -n "$(find "$APP/Contents/Resources/Videx_Videx.bundle" -name ejs-core.min.js -print -quit)"
echo "打包完成：$APP ($CONFIGURATION)"
