#!/bin/bash
# Remove COMPLETAMENTE o Soprano: fecha o app, devolve o fan ao automatico,
# apaga o binario privilegiado + regra sudo, o bundle .app e as preferencias.
set -uo pipefail
cd "$(dirname "$0")"

DEST=/usr/local/bin/smcfan
SUDOERS=/etc/sudoers.d/soprano
APP="build/Soprano.app"
BUNDLE_ID=com.bellini.soprano

echo "==> fechando o Soprano (se estiver aberto)"
osascript -e 'quit app "Soprano"' 2>/dev/null || true
pkill -x Soprano 2>/dev/null || true

if [ -x "$DEST" ]; then
    echo "==> devolvendo o(s) fan(s) ao controle automatico"
    sudo -n "$DEST" auto 2>/dev/null || sudo "$DEST" auto || true
fi

echo "==> removendo $DEST e regras sudo (precisa de sudo)"
# Remove a regra atual e tambem a antiga (fanslider), caso exista.
sudo rm -f "$DEST" "$SUDOERS" /etc/sudoers.d/fanslider

echo "==> apagando o app e as preferencias"
rm -rf "$APP"
defaults delete "$BUNDLE_ID" 2>/dev/null || true

echo "==> pronto. Soprano removido por completo."
echo "    Para instalar de novo: ./build.sh && ./install.sh"
