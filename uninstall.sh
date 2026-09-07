#!/usr/bin/env bash
#
# uninstall.sh - rimuove il comando wp-site.sh installato da install.sh
#
#   sudo ./uninstall.sh [--prefix /usr/local/bin]
#
# Nota: non tocca siti, database o backup gia' creati con 'wp-site.sh create',
# rimuove solo il comando.
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

DEST="$PREFIX/wp-site.sh"
if [[ -f "$DEST" ]]; then
  rm -f "$DEST"
  echo "[ok] rimosso $DEST"
else
  echo "[!] $DEST non trovato, niente da rimuovere"
fi
