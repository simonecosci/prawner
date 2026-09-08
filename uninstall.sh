#!/usr/bin/env bash
#
# uninstall.sh - remove the prawner project commands installed by install.sh
#
#   sudo ./uninstall.sh [--prefix /usr/local/bin] [--with-cron]
#
# Note: it does not touch sites, databases or backups already created with
# 'wp-site.sh create' or by 'wp-update.sh' runs; it only removes the commands
# (and optionally the cron job).
#
set -euo pipefail

PREFIX="/usr/local/bin"
WITH_CRON=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)    PREFIX="$2"; shift 2 ;;
    --with-cron) WITH_CRON=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "[ERROR] root required (use sudo)" >&2
  exit 1
fi

for name in wp-site.sh wp-update.sh wp-media-clean.sh; do
  DEST="$PREFIX/$name"
  if [[ -f "$DEST" ]]; then
    rm -f "$DEST"
    echo "[ok] removed $DEST"
  else
    echo "[!] $DEST not found, nothing to remove"
  fi
done

if [[ $WITH_CRON -eq 1 ]]; then
  CRON_DEST="/etc/cron.d/wp-update"
  if [[ -f "$CRON_DEST" ]]; then
    rm -f "$CRON_DEST"
    echo "[ok] removed $CRON_DEST"
  else
    echo "[!] $CRON_DEST not found, nothing to remove"
  fi
fi
