#!/bin/zsh
# Builds "pink diamond.app" into build/. Needs macOS 27 and Xcode (SwiftUI, MusicUnderstanding).
#   ./bundle.sh            build
#   ./bundle.sh --install  and copy it to /Applications
set -e
cd "${0:A:h}"
APP_NAME="pink diamond"
BUNDLE_ID="io.github.peyton-c.pinkdiamond"
VERSION="1.0.0"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
TARGET=arm64-apple-macos27.0

rm -rf build/obj && mkdir -p build/obj
xcrun clang -target $TARGET -c Sources/Core/Trampoline.s -o build/obj/Trampoline.o
xcrun swiftc -target $TARGET -O -swift-version 5 -parse-as-library -module-name PinkDiamond \
    Sources/Core/*.swift Sources/UI/*.swift build/obj/Trampoline.o \
    -o build/obj/pinkdiamond

APP="build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/obj/pinkdiamond "$APP/Contents/MacOS/$APP_NAME"
# App icon: compile the Icon Composer file into Assets.car (+ .icns fallback).
ICON=assets/pink_diamond.icon
if [ -d "$ICON" ]; then
    xcrun actool "$ICON" --compile "$APP/Contents/Resources" --platform macosx --minimum-deployment-target 27.0 \
        --app-icon pink_diamond --output-partial-info-plist build/obj/icon.plist > /dev/null
fi
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>pink_diamond</string>
  <key>CFBundleIconName</key><string>pink_diamond</string>
  <key>LSMinimumSystemVersion</key><string>27.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
</dict></plist>
EOF
codesign -f -s - "$APP"
echo "built $APP"

if [[ "$1" == "--install" ]]; then
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" /Applications/
    echo "installed /Applications/$APP_NAME.app"
fi
