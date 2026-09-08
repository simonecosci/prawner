#!/usr/bin/env bash
#
# install.sh - install the prawner project commands on this VPS
#
#   sudo ./install.sh [--prefix /usr/local/bin] [--with-cron]
#
#   --with-cron  also installs /etc/cron.d/wp-update (automatic daily
#                site updates via wp-update.sh)
#
set -euo pipefail

PREFIX="/usr/local/bin"
WITH_CRON=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)     PREFIX="$2"; shift 2 ;;
    --with-cron)  WITH_CRON=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "[ERROR] root required (use sudo)" >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

for name in wp-site.sh wp-update.sh wp-media-clean.sh; do
  SRC="$SCRIPT_DIR/bin/$name"
  DEST="$PREFIX/$name"
  [[ -f "$SRC" ]] || { echo "[ERROR] cannot find $SRC" >&2; exit 1; }
  install -m 0755 "$SRC" "$DEST"
  echo "[ok] installed in $DEST"
done

if [[ $WITH_CRON -eq 1 ]]; then
  CRON_SRC="$SCRIPT_DIR/cron.d/wp-update"
  CRON_DEST="/etc/cron.d/wp-update"
  [[ -f "$CRON_SRC" ]] || { echo "[ERROR] cannot find $CRON_SRC" >&2; exit 1; }
  install -o root -g root -m 0644 "$CRON_SRC" "$CRON_DEST"
  mkdir -p /var/log/wp-update
  echo "[ok] cron installed in $CRON_DEST (daily update at 03:30)"
fi

missing=()
for cmd in nginx wp mysql certbot openssl curl; do
  command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done

if [[ ${#missing[@]} -gt 0 ]]; then
  echo "[!] missing dependencies: ${missing[*]}"
  echo "    install them before using 'wp-site.sh create' or 'wp-site.sh cert'"
fi

echo
echo "Usage: wp-site.sh list | create <domain> | cert <domain> | remove <domain>"
echo "       wp-update.sh [--dry-run] [--site <domain>] [--no-core] [--skip-smoke]"
echo "       wp-media-clean.sh [--site <domain>] [--apply] [--only <class>]"
if [[ $WITH_CRON -eq 0 ]]; then
  echo
  echo "For automatic daily updates: sudo ./install.sh --with-cron"
  echo "(or copy cron.d/wp-update to /etc/cron.d/wp-update by hand)"
fi
