#!/usr/bin/env bash
#
# install.sh - installa i comandi del progetto prawner su questo VPS
#
#   sudo ./install.sh [--prefix /usr/local/bin] [--with-cron]
#
#   --with-cron  installa anche /etc/cron.d/wp-update (aggiornamento
#                giornaliero automatico dei siti via wp-update.sh)
#
set -euo pipefail

PREFIX="/usr/local/bin"
WITH_CRON=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)     PREFIX="$2"; shift 2 ;;
    --with-cron)  WITH_CRON=1; shift ;;
    *) echo "opzione sconosciuta: $1" >&2; exit 1 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "[ERRORE] serve root (usa sudo)" >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

for name in wp-site.sh wp-update.sh; do
  SRC="$SCRIPT_DIR/bin/$name"
  DEST="$PREFIX/$name"
  [[ -f "$SRC" ]] || { echo "[ERRORE] non trovo $SRC" >&2; exit 1; }
  install -m 0755 "$SRC" "$DEST"
  echo "[ok] installato in $DEST"
done

if [[ $WITH_CRON -eq 1 ]]; then
  CRON_SRC="$SCRIPT_DIR/cron.d/wp-update"
  CRON_DEST="/etc/cron.d/wp-update"
  [[ -f "$CRON_SRC" ]] || { echo "[ERRORE] non trovo $CRON_SRC" >&2; exit 1; }
  install -o root -g root -m 0644 "$CRON_SRC" "$CRON_DEST"
  mkdir -p /var/log/wp-update
  echo "[ok] cron installato in $CRON_DEST (aggiornamento giornaliero alle 03:30)"
fi

missing=()
for cmd in nginx wp mysql certbot openssl curl; do
  command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done

if [[ ${#missing[@]} -gt 0 ]]; then
  echo "[!] dipendenze mancanti: ${missing[*]}"
  echo "    installale prima di usare 'wp-site.sh create' o 'wp-site.sh cert'"
fi

echo
echo "Uso: wp-site.sh list | create <dominio> | cert <dominio> | remove <dominio>"
echo "     wp-update.sh [--dry-run] [--site <dominio>] [--no-core] [--skip-smoke]"
if [[ $WITH_CRON -eq 0 ]]; then
  echo
  echo "Per l'aggiornamento automatico giornaliero: sudo ./install.sh --with-cron"
  echo "(oppure copia a mano cron.d/wp-update in /etc/cron.d/wp-update)"
fi
