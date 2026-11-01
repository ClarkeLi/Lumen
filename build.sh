#!/bin/zsh
# Baut "Claude Traffic Light.app" und installiert es nach ~/Applications.
set -e
cd "$(dirname "$0")"
APP="build/Claude Traffic Light.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 分别编译 arm64 和 x86_64，再合并为 universal 二进制，Apple 芯片和 Intel Mac 都能直接运行
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
for ARCH in arm64 x86_64; do
  swiftc -O Sources/main.swift -o "$TMP/ClaudeTrafficLight-$ARCH" \
    -framework AppKit -framework ServiceManagement -target "$ARCH-apple-macos13.0"
done
lipo -create -output "$APP/Contents/MacOS/ClaudeTrafficLight" \
  "$TMP/ClaudeTrafficLight-arm64" "$TMP/ClaudeTrafficLight-x86_64"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Claude Traffic Light</string>
  <key>CFBundleDisplayName</key><string>Claude 红绿灯</string>
  <key>CFBundleIdentifier</key><string>local.claude.trafficlight</string>
  <key>CFBundleExecutable</key><string>ClaudeTrafficLight</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

xattr -cr "$APP"
codesign --force --sign - "$APP"

if [[ "$1" == "--install" ]]; then
  mkdir -p ~/Applications
  pkill -x ClaudeTrafficLight 2>/dev/null || true
  rm -rf ~/Applications/"Claude Traffic Light.app"
  cp -R "$APP" ~/Applications/
  open ~/Applications/"Claude Traffic Light.app"
  echo "Installiert und gestartet: ~/Applications/Claude Traffic Light.app"
else
  echo "Gebaut: $APP  (mit --install nach ~/Applications kopieren und starten)"
fi
