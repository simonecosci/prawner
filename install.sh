#!/usr/bin/env bash
#
# install.sh - installa il comando wp-site (progetto prawner) su questo VPS
#
#   sudo ./install.sh [--prefix /usr/local/bin]
#
set -euo pipefail

PREFIX="/usr/local/bin"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix) PREFIX="$2"; shift 2 ;;
    *) echo "opzione sconosciuta: $1" >&2; exit 1 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "[ERRORE] serve root (usa sudo)" >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
SRC="$SCRIPT_DIR/bin/wp-site.sh"
DEST="$PREFIX/wp-site.sh"

[[ -f "$SRC" ]] || { echo "[ERRORE] non trovo $SRC" >&2; exit 1; }

install -m 0755 "$SRC" "$DEST"
echo "[ok] installato in $DEST"

missing=()
for cmd in nginx wp mysql certbot openssl curl; do
  command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done

if [[ ${#missing[@]} -gt 0 ]]; then
  echo "[!] dipendenze mancanti: ${missing[*]}"
  echo "    installale prima di usare 'wp-site create' o 'wp-site cert'"
fi

echo
echo "Uso: wp-site.sh list | create <dominio> | cert <dominio> | remove <dominio>"
