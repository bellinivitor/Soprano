#!/bin/bash
# Compila o smcfan (CLI) e o Soprano.app (menu bar). Nao precisa de root.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build

echo "==> compilando smcfan"
swiftc -O -import-objc-header smcfan/SMC.h smcfan/SMC.swift smcfan/main.swift \
    -o build/smcfan -framework IOKit

echo "==> compilando Soprano.app"
APP="build/Soprano.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -import-objc-header smcfan/SMC.h smcfan/SMC.swift app/App.swift \
    -o "$APP/Contents/MacOS/Soprano" -framework IOKit

# Icone do app (Spotlight, Finder, Dock, etc.)
cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>Soprano</string>
    <key>CFBundleDisplayName</key>     <string>Soprano</string>
    <key>CFBundleIdentifier</key>      <string>com.bellini.soprano</string>
    <key>CFBundleVersion</key>         <string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleExecutable</key>      <string>Soprano</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>LSUIElement</key>             <true/>
</dict>
</plist>
PLIST

# Assinatura ad-hoc: deixa o app rodar localmente sem alertas de "app danificado".
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "==> pronto:"
echo "    build/smcfan"
echo "    build/Soprano.app"
echo ""
echo "Proximo passo: ./install.sh (pede sua senha uma vez)"
