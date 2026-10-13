#!/bin/zsh
# Build DimIt.app and install it to ~/Applications.
set -euo pipefail
cd "${0:A:h}"

APP=build/DimIt.app
rm -rf build
mkdir -p "$APP/Contents/MacOS"

swiftc -O -swift-version 5 DimIt.swift -o "$APP/Contents/MacOS/DimIt"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>DimIt</string>
  <key>CFBundleIdentifier</key><string>com.rob.dimit</string>
  <key>CFBundleExecutable</key><string>DimIt</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
EOF

codesign --force --sign - "$APP"

mkdir -p ~/Applications
pkill -x DimIt 2>/dev/null || true
rm -rf ~/Applications/DimIt.app
cp -R "$APP" ~/Applications/
echo "Installed ~/Applications/DimIt.app"
