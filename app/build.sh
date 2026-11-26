#!/bin/zsh
# Compila Notetaker.app in ~/Applications: eseguibile Swift, Info.plist, icona, firma ad hoc.
set -euo pipefail
B="${0:A:h:h}"
APP="$HOME/Applications/Notetaker.app"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

swiftc -O -target arm64-apple-macos13.0 -o "$TMP/Notetaker" "$B/app/Notetaker.swift" -framework AppKit -framework WebKit
"$B/venv/bin/python" "$B/app/icona.py" "$TMP/Notetaker.iconset"
iconutil -c icns -o "$TMP/Notetaker.icns" "$TMP/Notetaker.iconset"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$TMP/Notetaker" "$APP/Contents/MacOS/Notetaker"
cp "$TMP/Notetaker.icns" "$APP/Contents/Resources/Notetaker.icns"
cat >"$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>io.github.fraberret.notetaker</string>
  <key>CFBundleName</key><string>Notetaker</string>
  <key>CFBundleDisplayName</key><string>Notetaker</string>
  <key>CFBundleExecutable</key><string>Notetaker</string>
  <key>CFBundleIconFile</key><string>Notetaker</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleDevelopmentRegion</key><string>it</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST
codesign --force -s - "$APP"
touch "$APP"
echo "Creata $APP"
