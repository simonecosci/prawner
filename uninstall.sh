#!/usr/bin/env bash
#
# uninstall.sh - rimuove i comandi del progetto prawner installati da install.sh
#
#   sudo ./uninstall.sh [--prefix /usr/local/bin] [--with-cron]
#
# Nota: non tocca siti, database o backup gia' creati con 'wp-site.sh create'
# o dai run di 'wp-update.sh', rimuove solo i comandi (ed eventualmente il cron).
#
set -euo pipefail

PREFIX="/usr/local/bin"
WITH_CRON=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)    PREFIX="$2"; shift 2 ;;
    --with-cron) WITH_CRON=1; shift ;;
    *) echo "opzione sconosciuta: $1" >&2; exit 1 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "[ERRORE] serve root (usa sudo)" >&2
  exit 1
fi

for name in wp-site.sh wp-update.sh; do
  DEST="$PREFIX/$name"
  if [[ -f "$DEST" ]]; then
    rm -f "$DEST"
    echo "[ok] rimosso $DEST"
  else
    echo "[!] $DEST non trovato, niente da rimuovere"
  fi
done

if [[ $WITH_CRON -eq 1 ]]; then
  CRON_DEST="/etc/cron.d/wp-update"
  if [[ -f "$CRON_DEST" ]]; then
    rm -f "$CRON_DEST"
    echo "[ok] rimosso $CRON_DEST"
  else
    echo "[!] $CRON_DEST non trovato, niente da rimuovere"
  fi
fi
