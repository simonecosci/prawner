#!/usr/bin/env bash
#
# wp-update.sh - aggiorna core, plugin e temi di tutte le installazioni
#                WordPress presenti in /var/www/*/wordpress
#
# Per ogni sito:
#   1. dump del DB + tar di plugins/themes/mu-plugins
#   2. update core -> plugin -> temi -> update-db
#   3. smoke test HTTP
#   4. rollback automatico se lo smoke test fallisce
#
# Uso:
#   ./wp-update.sh                      # aggiorna tutto
#   ./wp-update.sh --dry-run            # mostra solo cosa verrebbe aggiornato
#   ./wp-update.sh --site punto14.es    # un solo sito
#   ./wp-update.sh --no-core            # solo plugin e temi
#   ./wp-update.sh --skip-smoke         # salta il controllo HTTP (e il rollback)
#
set -uo pipefail

WWW_ROOT="${WWW_ROOT:-/var/www}"
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/wp}"
LOG_DIR="${LOG_DIR:-/var/log/wp-update}"
KEEP_BACKUPS="${KEEP_BACKUPS:-3}"      # quanti set di backup tenere per sito
MIN_FREE_MB="${MIN_FREE_MB:-1024}"     # spazio libero minimo richiesto
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
    *)            echo "Opzione sconosciuta: $1" >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------- helpers

mkdir -p "$LOG_DIR" "$BACKUP_ROOT"

log()  { printf '%s  %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"; }
warn() { printf '%s  [WARN] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE" >&2; }
err()  { printf '%s  [ERR ] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE" >&2; }

# Esegue wp-cli con l'utente proprietario dell'installazione.
# I file creati dagli update restano quindi di proprieta' corretta.
# www-data e gli utenti ftp hanno HOME non scrivibile (/var/www, /usr/sbin/nologin).
# Una cache condivisa non basta: wp-cli crea le sottocartelle (theme/, plugin/,
# core/) con l'utente del primo run e gli altri owner non ci possono scrivere.
# Quindi una cache per utente.
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
    err "comandi mancanti: ${missing[*]}"
    exit 1
  fi
}

check_disk() {
  local free_mb
  free_mb=$(df -Pm "$BACKUP_ROOT" | awk 'NR==2 {print $4}')
  if [[ "$free_mb" -lt "$MIN_FREE_MB" ]]; then
    err "spazio libero insufficiente su $BACKUP_ROOT: ${free_mb}MB (minimo ${MIN_FREE_MB}MB)"
    exit 1
  fi
}

# ---------------------------------------------------------------- backup

do_backup() {
  local dir="$BACKUP_ROOT/$SITE_SLUG/$STAMP"
  mkdir -p "$dir"

  log "  backup DB -> $dir/db.sql.gz"
  if ! wp_run db export - --single-transaction --quick --default-character-set=utf8mb4 \
       | gzip -c > "$dir/db.sql.gz"; then
    err "  dump del DB fallito, sito saltato"
    rm -rf "$dir"
    return 1
  fi
  # gzip di un errore wp-cli produce un file minuscolo: sanity check
  if [[ $(stat -c %s "$dir/db.sql.gz") -lt 1024 ]]; then
    err "  dump del DB sospettosamente piccolo, sito saltato"
    rm -rf "$dir"
    return 1
  fi

  log "  backup wp-content (plugins/themes/mu-plugins, esclusi uploads)"
  tar -czf "$dir/wp-content.tar.gz" \
      -C "$SITE_PATH" \
      $( [[ -d "$SITE_PATH/wp-content/plugins"    ]] && echo wp-content/plugins ) \
      $( [[ -d "$SITE_PATH/wp-content/themes"     ]] && echo wp-content/themes ) \
      $( [[ -d "$SITE_PATH/wp-content/mu-plugins" ]] && echo wp-content/mu-plugins ) \
      2>>"$LOG_FILE" || { err "  tar fallito"; return 1; }

  # versione core prima dell'update, serve per il rollback
  wp_run core version > "$dir/core.version" 2>/dev/null

  BACKUP_DIR="$dir"
  return 0
}

prune_backups() {
  local site_dir="$BACKUP_ROOT/$SITE_SLUG"
  [[ -d "$site_dir" ]] || return 0
  ls -1dt "$site_dir"/*/ 2>/dev/null | tail -n +$((KEEP_BACKUPS + 1)) | while read -r old; do
    log "  rimuovo backup vecchio: $old"
    rm -rf "$old"
  done
}

# ---------------------------------------------------------------- smoke test

smoke_test() {
  local url code body_file
  url=$(wp_run option get home | tr -d '\r\n')
  [[ -z "$url" ]] && { warn "  home url non leggibile, smoke test saltato"; return 0; }

  body_file=$(mktemp)
  code=$(curl -sS -L --max-time "$CURL_TIMEOUT" -o "$body_file" -w '%{http_code}' "$url" || echo 000)

  if [[ "$code" != "200" ]]; then
    err "  smoke test: HTTP $code su $url"
    rm -f "$body_file"; return 1
  fi
  if grep -qiE 'there has been a critical error|error establishing a database connection|Fatal error' "$body_file"; then
    err "  smoke test: errore PHP/DB nella pagina"
    rm -f "$body_file"; return 1
  fi
  if [[ $(stat -c %s "$body_file") -lt 500 ]]; then
    err "  smoke test: risposta troppo corta (${code}), possibile white screen"
    rm -f "$body_file"; return 1
  fi

  log "  smoke test OK ($url -> $code)"
  rm -f "$body_file"

  # Secondo controllo: wp-login.php. Plugin che toccano SSL, redirect o header
  # rompono spesso il login lasciando la home perfettamente funzionante.
  local login_code
  login_code=$(curl -sS -L --max-time "$CURL_TIMEOUT" -o /dev/null \
                    -w '%{http_code}' "$url/wp-login.php" || echo 000)
  if [[ "$login_code" != "200" ]]; then
    err "  smoke test: wp-login.php risponde $login_code (redirect loop? SSL?)"
    return 1
  fi
  log "  smoke test login OK"
  return 0
}

# ---------------------------------------------------------------- rollback

do_rollback() {
  warn "  ROLLBACK in corso da $BACKUP_DIR"

  if [[ -f "$BACKUP_DIR/core.version" ]]; then
    local v; v=$(cat "$BACKUP_DIR/core.version")
    log "  ripristino core $v"
    wp_run core download --version="$v" --force --skip-content >/dev/null
  fi

  log "  ripristino plugins/themes"
  tar -xzf "$BACKUP_DIR/wp-content.tar.gz" -C "$SITE_PATH" 2>>"$LOG_FILE"
  chown -R "$SITE_OWNER":"$SITE_GROUP" "$SITE_PATH/wp-content" 2>/dev/null

  log "  ripristino DB"
  gunzip -c "$BACKUP_DIR/db.sql.gz" | wp_run db import - >/dev/null

  wp_run maintenance-mode deactivate >/dev/null 2>&1

  if smoke_test; then
    warn "  rollback riuscito, sito tornato allo stato precedente"
  else
    err "  ROLLBACK NON RISOLUTIVO su $SITE_NAME - intervento manuale necessario"
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

  log "  da aggiornare: core=$pending_core plugin=$pending_plugins temi=$pending_themes"

  if [[ $DRY_RUN -eq 1 ]]; then
    [[ "$pending_plugins" -gt 0 ]] && wp_run plugin list --update=available \
        --fields=name,version,update_version --format=table | tee -a "$LOG_FILE"
    [[ "$pending_themes" -gt 0 ]] && wp_run theme list --update=available \
        --fields=name,version,update_version --format=table | tee -a "$LOG_FILE"
    return 0
  fi

  if [[ "$pending_core" -eq 0 && "$pending_plugins" -eq 0 && "$pending_themes" -eq 0 ]]; then
    log "  gia' aggiornato, niente da fare"
    return 0
  fi

  do_backup || return 1

  wp_run maintenance-mode activate >/dev/null 2>&1

  if [[ $DO_CORE -eq 1 && "$pending_core" -gt 0 ]]; then
    log "  update core"
    wp_run core update | tee -a "$LOG_FILE"
  fi
  if [[ "$pending_plugins" -gt 0 ]]; then
    log "  update plugin"
    wp_run plugin update --all | tee -a "$LOG_FILE"
  fi
  if [[ "$pending_themes" -gt 0 ]]; then
    log "  update temi"
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

# Trova ogni installazione reale invece di assumere <dominio>/wordpress:
# cosi' vengono presi anche wordpress-test e installazioni in root di dominio.
# L'ordinamento mette per primi i path che contengono "test": canarino.
mapfile -t CONFIGS < <(
  find "$WWW_ROOT" -mindepth 2 -maxdepth 3 -name wp-config.php \
       -not -path '*/wp-content/*' 2>/dev/null \
  | awk '{ print ($0 ~ /test/ ? 0 : 1) "\t" $0 }' | sort | cut -f2-
)

for cfg in "${CONFIGS[@]}"; do
  SITE_PATH=$(dirname "$cfg")
  SITE_NAME=${SITE_PATH#"$WWW_ROOT"/}          # es. simonecosci.com/wordpress-test
  SITE_SLUG=${SITE_NAME//\//_}                 # es. simonecosci.com_wordpress-test

  if [[ -n "$ONLY_SITE" && "$SITE_NAME" != *"$ONLY_SITE"* ]]; then
    continue
  fi

  SITE_OWNER=$(stat -c %U "$SITE_PATH")
  setup_cache_dir
  SITE_GROUP=$(stat -c %G "$SITE_PATH")
  BACKUP_DIR=""

  log "--- $SITE_NAME ($SITE_PATH, owner=$SITE_OWNER:$SITE_GROUP)"

  if ! wp_run core is-installed >/dev/null 2>&1; then
    warn "  wp-cli non riesce a caricare l'installazione (DB down? wp-config?), salto"
    FAILED+=("$SITE_NAME (non raggiungibile)")
    continue
  fi

  if update_site; then
    OK+=("$SITE_NAME")
  else
    FAILED+=("$SITE_NAME")
  fi
done

log "=== fine: ${#OK[@]} ok, ${#FAILED[@]} falliti ==="
[[ ${#FAILED[@]} -gt 0 ]] && err "siti con problemi: ${FAILED[*]}"

# exit code != 0 se qualcosa e' andato storto, utile per cron/monitoring
[[ ${#FAILED[@]} -eq 0 ]]