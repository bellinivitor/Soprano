#!/bin/bash
# Instala o smcfan em /usr/local/bin e libera o sudo sem senha SO para ele,
# para o slider poder escrever no SMC sem pedir senha a cada movimento.
# Pede sua senha uma unica vez.
set -euo pipefail
cd "$(dirname "$0")"

BIN=build/smcfan
DEST=/usr/local/bin/smcfan
SUDOERS=/etc/sudoers.d/soprano
USER_NAME="$(id -un)"

if [ ! -x "$BIN" ]; then
    echo "erro: $BIN nao existe. Rode ./build.sh antes." >&2
    exit 1
fi

echo "==> instalando smcfan em $DEST (precisa de sudo)"
sudo install -m 0755 "$BIN" "$DEST"

echo "==> criando regra sudoers em $SUDOERS"
# Valida a sintaxe antes de instalar (visudo -c evita travar o sudo).
TMP="$(mktemp)"
printf '%s ALL=(root) NOPASSWD: %s\n' "$USER_NAME" "$DEST" > "$TMP"
sudo visudo -cf "$TMP" >/dev/null
sudo install -m 0440 "$TMP" "$SUDOERS"
rm -f "$TMP"

echo ""
echo "==> pronto. Testando escrita sem senha:"
if sudo -n "$DEST" read >/dev/null 2>&1; then
    echo "    OK — o slider ja pode controlar o fan."
else
    echo "    aviso: sudo -n ainda pediu senha; confira $SUDOERS"
fi

echo ""
echo "Para abrir o app:  open build/Soprano.app"
echo "Para desinstalar:  ./uninstall.sh"
