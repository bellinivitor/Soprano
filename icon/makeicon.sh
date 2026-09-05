#!/bin/bash
# Gera AppIcon.icns a partir do desenho em makeicon.swift.
# Uso: ./makeicon.sh   (dentro da pasta icon/)
set -euo pipefail
cd "$(dirname "$0")"

echo "==> desenhando o icone (1024px)"
swift makeicon.swift

echo "==> montando os tamanhos"
SET=AppIcon.iconset
rm -rf "$SET"; mkdir "$SET"
sips -z 16 16     icon_1024.png --out "$SET/icon_16x16.png"      >/dev/null
sips -z 32 32     icon_1024.png --out "$SET/icon_16x16@2x.png"   >/dev/null
sips -z 32 32     icon_1024.png --out "$SET/icon_32x32.png"      >/dev/null
sips -z 64 64     icon_1024.png --out "$SET/icon_32x32@2x.png"   >/dev/null
sips -z 128 128   icon_1024.png --out "$SET/icon_128x128.png"    >/dev/null
sips -z 256 256   icon_1024.png --out "$SET/icon_128x128@2x.png" >/dev/null
sips -z 256 256   icon_1024.png --out "$SET/icon_256x256.png"    >/dev/null
sips -z 512 512   icon_1024.png --out "$SET/icon_256x256@2x.png" >/dev/null
sips -z 512 512   icon_1024.png --out "$SET/icon_512x512.png"    >/dev/null
cp icon_1024.png "$SET/icon_512x512@2x.png"

echo "==> gerando AppIcon.icns"
iconutil -c icns "$SET" -o AppIcon.icns
rm -rf "$SET" icon_1024.png
echo "==> pronto: icon/AppIcon.icns"
