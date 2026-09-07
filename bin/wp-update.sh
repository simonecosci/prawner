#!/usr/bin/env bash
#
# wp-update.sh - updates core, plugins and themes of every WordPress
#                installation found under /var/www/*/wordpress
#
# For each site:
#   1. DB dump + tar of plugins/themes/mu-plugins
#   2. update core -> plugins -> themes -> update-db
#   3. HTTP smoke test
#   4. automatic rollback if the smoke test fails
#
# Usage:
#   ./wp-update.sh                      # update everything
#   ./wp-update.sh --dry-run            # only show what would be updated
#   ./wp-update.sh --site example.com   # a single site
#   ./wp-update.sh --no-core            # plugins and themes only
#   ./wp-update.sh --skip-smoke         # skip the HTTP check (and the rollback)
#
set -uo pipefail

WWW_ROOT="${WWW_ROOT:-/var/www}"
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/wp}"
LOG_DIR="${LOG_DIR:-/var/log/wp-update}"
KEEP_BACKUPS="${KEEP_BACKUPS:-3}"      # how many backup sets to keep per site
MIN_FREE_MB="${MIN_FREE_MB:-1024}"     # minimum free space required
CURL_TIMEOUT="${CURL_TIMEOUT:-30}"

DRY_RUN=0
ONLY_SITE=""
DO_CORE=1
SKIP_SMOKE=0

STAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="$LOG_DIR/$STAMP.log"

# ---------------------------------------------------------------- args

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)    DRY_RUN=1; shift ;;
    --site)       ONLY_SITE="$2"; shift 2 ;;
    --no-core)    DO_CORE=0; shift ;;
    --skip-smoke) SKIP_SMOKE=1; shift ;;
    -h|--help)    sed -n '2,20p' "$0"; exit 0 ;;
    *)            echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------- helpers

mkdir -p "$LOG_DIR" "$BACKUP_ROOT"

log()  { printf '%s  %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"; }
warn() { printf '%s  [WARN] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE" >&2; }
err()  { printf '%s  [ERR ] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE" >&2; }

# Runs wp-cli as the user owning the installation, so the files created by
# the updates keep the correct ownership.
# www-data and the ftp users have a non-writable HOME (/var/www, /usr/sbin/nologin).
# A shared cache is not enough: wp-cli creates the subdirectories (theme/,
# plugin/, core/) as the user of the first run and the other owners cannot
# write into them. Hence one cache per user.
WP_CLI_CACHE_ROOT="${WP_CLI_CACHE_ROOT:-/var/cache/wp-cli}"

setup_cache_dir() {
  SITE_CACHE_DIR="$WP_CLI_CACHE_ROOT/$SITE_OWNER"
  install -d -o "$SITE_OWNER" -m 0755 "$SITE_CACHE_DIR" 2>/dev/null \
    || { mkdir -p "$SITE_CACHE_DIR"; chown -R "$SITE_OWNER" "$SITE_CACHE_DIR"; }
}

wp_run() {
  if [[ "$SITE_OWNER" == "root" ]]; then
    env WP_CLI_CACHE_DIR="$SITE_CACHE_DIR" \
        wp --path="$SITE_PATH" --allow-root "$@" 2>&1
  else
    sudo -u "$SITE_OWNER" env WP_CLI_CACHE_DIR="$SITE_CACHE_DIR" HOME=/tmp \
        wp --path="$SITE_PATH" "$@" 2>&1
  fi
}

require_cmds() {
  local missing=()
  for c in wp curl tar gzip stat sudo; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    err "missing commands: ${missing[*]}"
    exit 1
  fi
}

check_disk() {
  local free_mb
  free_mb=$(df -Pm "$BACKUP_ROOT" | awk 'NR==2 {print $4}')
  if [[ "$free_mb" -lt "$MIN_FREE_MB" ]]; then
    err "not enough free space on $BACKUP_ROOT: ${free_mb}MB (minimum ${MIN_FREE_MB}MB)"
    exit 1
  fi
}

# ---------------------------------------------------------------- backup

do_backup() {
  local dir="$BACKUP_ROOT/$SITE_SLUG/$STAMP"
  mkdir -p "$dir"

  log "  DB backup -> $dir/db.sql.gz"
  if ! wp_run db export - --single-transaction --quick --default-character-set=utf8mb4 \
       | gzip -c > "$dir/db.sql.gz"; then
    err "  DB dump failed, site skipped"
    rm -rf "$dir"
    return 1
  fi
  # gzipping a wp-cli error produces a tiny file: sanity check
  if [[ $(stat -c %s "$dir/db.sql.gz") -lt 1024 ]]; then
    err "  DB dump suspiciously small, site skipped"
    rm -rf "$dir"
    return 1
  fi

  log "  wp-content backup (plugins/themes/mu-plugins, uploads excluded)"
  tar -czf "$dir/wp-content.tar.gz" \
      -C "$SITE_PATH" \
      $( [[ -d "$SITE_PATH/wp-content/plugins"    ]] && echo wp-content/plugins ) \
      $( [[ -d "$SITE_PATH/wp-content/themes"     ]] && echo wp-content/themes ) \
      $( [[ -d "$SITE_PATH/wp-content/mu-plugins" ]] && echo wp-content/mu-plugins ) \
      2>>"$LOG_FILE" || { err "  tar failed"; return 1; }

  # core version before the update, needed for the rollback
  wp_run core version > "$dir/core.version" 2>/dev/null

  BACKUP_DIR="$dir"
  return 0
}

prune_backups() {
  local site_dir="$BACKUP_ROOT/$SITE_SLUG"
  [[ -d "$site_dir" ]] || return 0
  ls -1dt "$site_dir"/*/ 2>/dev/null | tail -n +$((KEEP_BACKUPS + 1)) | while read -r old; do
    log "  removing old backup: $old"
    rm -rf "$old"
  done
}

# ---------------------------------------------------------------- smoke test

smoke_test() {
  local url code body_file
  url=$(wp_run option get home | tr -d '\r\n')
  [[ -z "$url" ]] && { warn "  home url not readable, smoke test skipped"; return 0; }

  body_file=$(mktemp)
  code=$(curl -sS -L --max-time "$CURL_TIMEOUT" -o "$body_file" -w '%{http_code}' "$url" || echo 000)

  if [[ "$code" != "200" ]]; then
    err "  smoke test: HTTP $code on $url"
    rm -f "$body_file"; return 1
  fi
  if grep -qiE 'there has been a critical error|error establishing a database connection|Fatal error' "$body_file"; then
    err "  smoke test: PHP/DB error in the page"
    rm -f "$body_file"; return 1
  fi
  if [[ $(stat -c %s "$body_file") -lt 500 ]]; then
    err "  smoke test: response too short (${code}), possible white screen"
    rm -f "$body_file"; return 1
  fi

  log "  smoke test OK ($url -> $code)"
  rm -f "$body_file"

  # Second check: wp-login.php. Plugins that touch SSL, redirects or headers
  # often break the login while leaving the home page perfectly working.
  local login_code
  login_code=$(curl -sS -L --max-time "$CURL_TIMEOUT" -o /dev/null \
                    -w '%{http_code}' "$url/wp-login.php" || echo 000)
  if [[ "$login_code" != "200" ]]; then
    err "  smoke test: wp-login.php returns $login_code (redirect loop? SSL?)"
    return 1
  fi
  log "  login smoke test OK"
  return 0
}

# ---------------------------------------------------------------- rollback

do_rollback() {
  warn "  ROLLBACK in progress from $BACKUP_DIR"

  if [[ -f "$BACKUP_DIR/core.version" ]]; then
    local v; v=$(cat "$BACKUP_DIR/core.version")
    log "  restoring core $v"
    wp_run core download --version="$v" --force --skip-content >/dev/null
  fi

  log "  restoring plugins/themes"
  tar -xzf "$BACKUP_DIR/wp-content.tar.gz" -C "$SITE_PATH" 2>>"$LOG_FILE"
  chown -R "$SITE_OWNER":"$SITE_GROUP" "$SITE_PATH/wp-content" 2>/dev/null

  log "  restoring DB"
  gunzip -c "$BACKUP_DIR/db.sql.gz" | wp_run db import - >/dev/null

  wp_run maintenance-mode deactivate >/dev/null 2>&1

  if smoke_test; then
    warn "  rollback succeeded, site back to its previous state"
  else
    err "  ROLLBACK DID NOT FIX $SITE_NAME - manual intervention required"
  fi
}

# ---------------------------------------------------------------- update

update_site() {
  local pending_core pending_plugins pending_themes

  pending_core=$(wp_run core check-update --format=count 2>/dev/null | tail -1)
  pending_plugins=$(wp_run plugin list --update=available --format=count 2>/dev/null | tail -1)
  pending_themes=$(wp_run theme list --update=available --format=count 2>/dev/null | tail -1)
  [[ "$pending_core"    =~ ^[0-9]+$ ]] || pending_core=0
  [[ "$pending_plugins" =~ ^[0-9]+$ ]] || pending_plugins=0
  [[ "$pending_themes"  =~ ^[0-9]+$ ]] || pending_themes=0

  log "  to update: core=$pending_core plugins=$pending_plugins themes=$pending_themes"

  if [[ $DRY_RUN -eq 1 ]]; then
    [[ "$pending_plugins" -gt 0 ]] && wp_run plugin list --update=available \
        --fields=name,version,update_version --format=table | tee -a "$LOG_FILE"
    [[ "$pending_themes" -gt 0 ]] && wp_run theme list --update=available \
        --fields=name,version,update_version --format=table | tee -a "$LOG_FILE"
    return 0
  fi

  if [[ "$pending_core" -eq 0 && "$pending_plugins" -eq 0 && "$pending_themes" -eq 0 ]]; then
    log "  already up to date, nothing to do"
    return 0
  fi

  do_backup || return 1

  wp_run maintenance-mode activate >/dev/null 2>&1

  if [[ $DO_CORE -eq 1 && "$pending_core" -gt 0 ]]; then
    log "  core update"
    wp_run core update | tee -a "$LOG_FILE"
  fi
  if [[ "$pending_plugins" -gt 0 ]]; then
    log "  plugin update"
    wp_run plugin update --all | tee -a "$LOG_FILE"
  fi
  if [[ "$pending_themes" -gt 0 ]]; then
    log "  theme update"
    wp_run theme update --all | tee -a "$LOG_FILE"
  fi

  wp_run core update-db | tee -a "$LOG_FILE"
  wp_run cache flush >/dev/null 2>&1
  wp_run maintenance-mode deactivate >/dev/null 2>&1

  if [[ $SKIP_SMOKE -eq 0 ]]; then
    if ! smoke_test; then
      do_rollback
      return 1
    fi
  fi

  prune_backups
  return 0
}

# ---------------------------------------------------------------- main

require_cmds
check_disk

log "=== wp-update start (dry-run=$DRY_RUN) ==="

FAILED=()
OK=()

# Find every real installation instead of assuming <domain>/wordpress:
# this also picks up wordpress-test and installations at the domain root.
# The sorting puts the paths containing "test" first: the canaries.
mapfile -t CONFIGS < <(
  find "$WWW_ROOT" -mindepth 2 -maxdepth 3 -name wp-config.php \
       -not -path '*/wp-content/*' 2>/dev/null \
  | awk '{ print ($0 ~ /test/ ? 0 : 1) "\t" $0 }' | sort | cut -f2-
)

for cfg in "${CONFIGS[@]}"; do
  SITE_PATH=$(dirname "$cfg")
  SITE_NAME=${SITE_PATH#"$WWW_ROOT"/}          # e.g. example.com/wordpress-test
  SITE_SLUG=${SITE_NAME//\//_}                 # e.g. example.com_wordpress-test

  if [[ -n "$ONLY_SITE" && "$SITE_NAME" != *"$ONLY_SITE"* ]]; then
    continue
  fi

  SITE_OWNER=$(stat -c %U "$SITE_PATH")
  setup_cache_dir
  SITE_GROUP=$(stat -c %G "$SITE_PATH")
  BACKUP_DIR=""

  log "--- $SITE_NAME ($SITE_PATH, owner=$SITE_OWNER:$SITE_GROUP)"

  if ! wp_run core is-installed >/dev/null 2>&1; then
    warn "  wp-cli cannot load the installation (DB down? wp-config?), skipping"
    FAILED+=("$SITE_NAME (unreachable)")
    continue
  fi

  if update_site; then
    OK+=("$SITE_NAME")
  else
    FAILED+=("$SITE_NAME")
  fi
done

log "=== done: ${#OK[@]} ok, ${#FAILED[@]} failed ==="
[[ ${#FAILED[@]} -gt 0 ]] && err "sites with problems: ${FAILED[*]}"

# exit code != 0 if something went wrong, useful for cron/monitoring
[[ ${#FAILED[@]} -eq 0 ]]
