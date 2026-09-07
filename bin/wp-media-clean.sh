#!/usr/bin/env bash
#
# wp-media-clean.sh - reclaim disk space by quarantining unused media in every
#                     WordPress installation found under /var/www
#                     (part of the prawner project)
#
#   wp-media-clean.sh                                  report only
#   wp-media-clean.sh --site example.com --apply       move to quarantine
#   wp-media-clean.sh --list-quarantine --site example.com
#   wp-media-clean.sh --restore <stamp> --site example.com
#
# Three classes of waste are handled:
#   attachments  attachment rows nothing references any more
#   orphans      files under uploads/ that belong to no attachment
#   thumbs       generated sizes the theme and plugins no longer register
#
# Nothing is ever deleted outright: removal moves files into
# $QUARANTINE_ROOT together with a dump of the affected database rows, and
# --restore puts them back. Real deletion only happens when a quarantine set
# falls out of the KEEP_QUARANTINE retention window.
#
set -uo pipefail

WWW_ROOT="${WWW_ROOT:-/var/www}"
QUARANTINE_ROOT="${QUARANTINE_ROOT:-/var/backups/wp-media}"
LOG_DIR="${LOG_DIR:-/var/log/wp-media-clean}"
WP_CLI_CACHE_ROOT="${WP_CLI_CACHE_ROOT:-/var/cache/wp-cli}"
KEEP_QUARANTINE="${KEEP_QUARANTINE:-3}"
MIN_AGE_DAYS="${MIN_AGE_DAYS:-30}"

ACTION="clean"          # clean | list-quarantine | restore
ONLY_SITE=""
ONLY_CLASS="all"        # all | attachments | orphans | thumbs
RESTORE_STAMP=""
APPLY=0
KEEP_ATTACHED=0
SCAN_FILES=1

STAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE=""

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_dim=$'\033[2m'; c_off=$'\033[0m'

die()  { printf '%s[ERROR]%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }
warn() { printf '%s[!]%s %s\n' "$c_yel" "$c_off" "$*" >&2; [[ -n "$LOG_FILE" ]] && printf '[!] %s\n' "$*" >>"$LOG_FILE"; return 0; }
ok()   { printf '%s[ok]%s %s\n' "$c_grn" "$c_off" "$*"; }
info() { printf '  %s\n' "$*"; }
log()  { printf '%s\n' "$*"; [[ -n "$LOG_FILE" ]] && printf '%s  %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE"; return 0; }

# ------------------------------------------------------- filename helpers
# Pure string functions. tests/run.sh sources this file and exercises them
# directly, so they must not touch global state or the filesystem.

# parse_thumb_size <filename>
# Recognises a WordPress generated size variant, "photo-800x600.jpg", and
# prints "<base>|<WxH>|<ext>". Returns 1 for anything else. The size has to sit
# at the very end of the name: "photo-800x600-detail.jpg" is a user filename
# that happens to contain digits, not a generated size.
parse_thumb_size() {
  local name="$1"
  [[ "$name" =~ ^(.+)-([0-9]+x[0-9]+)\.([A-Za-z0-9]+)$ ]] || return 1
  printf '%s|%s|%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
}

# canonical_original <filename>
# WordPress keeps several files per upload that are not thumbnails: oversized
# uploads become "<name>-scaled.<ext>" with the untouched "<name>.<ext>" left
# on disk, and the image editor writes "<name>-e<timestamp>.<ext>" and
# "<name>-rotated.<ext>". Strips such a suffix so the caller can check whether
# the file belongs to a known upload. The six digit floor on the -e form keeps
# ordinary filenames such as "phone-e5.jpg" intact.
canonical_original() {
  local name="$1"
  if [[ "$name" =~ ^(.+)-(scaled|rotated|e[0-9]{6,})\.([A-Za-z0-9]+)$ ]]; then
    printf '%s.%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}"
  else
    printf '%s\n' "$name"
  fi
}

# urlencode_name <filename>
# Percent-encodes a filename so that a reference written as "my%20photo.jpg"
# still matches the upload "my photo.jpg". LC_ALL=C makes the loop iterate over
# bytes rather than characters, which is what UTF-8 percent-encoding needs.
urlencode_name() {
  local LC_ALL=C
  local s="$1" out="" c hex i
  for (( i = 0; i < ${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      [A-Za-z0-9._~-]) out+="$c" ;;
      *) printf -v hex '%%%02X' "'$c"; out+="$hex" ;;
    esac
  done
  printf '%s\n' "$out"
}

# ------------------------------------------------------ reference helpers

# extract_id_tokens  (stdin -> stdout)
# Prints every integer that appears on stdin in a shape that identifies an
# attachment, one per line. Only patterned occurrences count:
#   i:123;          integers inside a serialized array (theme mods, builders)
#   s:3:"123"       numeric strings inside a serialized array
#   wp-image-123    the class the classic editor writes on <img>
#   "id":123        Gutenberg block attributes, also in their escaped form
# Bare integers are deliberately NOT collected here. Any four digit year in any
# post would otherwise become an attachment ID and nothing would ever be
# reported. The bare integer sources (ACF fields, _thumbnail_id) arrive through
# expand_id_list instead, from a query that already restricts the shape.
extract_id_tokens() {
  grep -oE 'i:[0-9]+;|s:[0-9]+:"[0-9]+"|wp-image-[0-9]+|"id":[0-9]+|&quot;id&quot;:[0-9]+' \
    | sed -E 's/^i:([0-9]+);$/\1/
              s/^s:[0-9]+:"([0-9]+)"$/\1/
              s/^wp-image-//
              s/^"id"://
              s/^&quot;id&quot;://'
}

# expand_id_list  (stdin -> stdout)
# Reads meta values that are already known to be an attachment reference and
# flattens them: "123" stays as is, the "12,45,78" of a WooCommerce gallery
# becomes three lines. Anything not a plain integer is dropped.
expand_id_list() {
  tr ',' '\n' | grep -oE '^[0-9]+$'
}

# name_is_used <filename>
# True when the haystack mentions this file. Both spellings are checked: the
# match written into used-names.txt is whatever the content actually contained,
# so a reference written as "my%20holiday.jpg" lands there in encoded form
# while the upload on disk is named "my holiday.jpg". Checking only the plain
# name would report that file as unused.
name_is_used() {
  local n="$1"
  grep -qxF "$n" "$WORK/used-names.txt" && return 0
  local enc; enc=$(urlencode_name "$n")
  [[ "$enc" != "$n" ]] && grep -qxF "$enc" "$WORK/used-names.txt"
}

# ------------------------------------------------------------- wp plumbing

require_cmds() {
  local missing=() c
  for c in wp mysql grep sed awk comm sort find stat sudo; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  [[ ${#missing[@]} -eq 0 ]] || die "missing commands: ${missing[*]}"
}

# Runs wp-cli as the user owning the installation, so anything it writes keeps
# the right ownership. Each owner gets its own cache: www-data and the ftp
# users have a non-writable HOME, and a shared cache directory ends up owned by
# whoever ran first.
wp_run() {
  if [[ "$SITE_OWNER" == "root" ]]; then
    env WP_CLI_CACHE_DIR="$SITE_CACHE_DIR" wp --path="$SITE_PATH" --allow-root "$@" 2>>"$LOG_FILE"
  else
    sudo -u "$SITE_OWNER" env WP_CLI_CACHE_DIR="$SITE_CACHE_DIR" HOME=/tmp \
      wp --path="$SITE_PATH" "$@" 2>>"$LOG_FILE"
  fi
}

# Finds every real installation rather than assuming <domain>/wordpress, the
# same way wp-update.sh does: this also picks up wordpress-test directories and
# installations sitting at the domain root.
discover_sites() {
  mapfile -t CONFIGS < <(
    find "$WWW_ROOT" -mindepth 2 -maxdepth 3 -name wp-config.php \
         -not -path '*/wp-content/*' 2>/dev/null | sort
  )
}

load_site() {
  local cfg="$1"
  SITE_PATH=$(dirname "$cfg")
  SITE_NAME=${SITE_PATH#"$WWW_ROOT"/}
  SITE_SLUG=${SITE_NAME//\//_}
  SITE_OWNER=$(stat -c %U "$SITE_PATH")
  SITE_GROUP=$(stat -c %G "$SITE_PATH")
  SITE_CACHE_DIR="$WP_CLI_CACHE_ROOT/$SITE_OWNER"
  install -d -o "$SITE_OWNER" -m 0755 "$SITE_CACHE_DIR" 2>/dev/null || {
    mkdir -p "$SITE_CACHE_DIR"; chown -R "$SITE_OWNER" "$SITE_CACHE_DIR"
  }

  wp_run core is-installed >/dev/null 2>&1 || {
    warn "  wp-cli cannot load the installation (DB down? wp-config?), skipping"
    return 1
  }

  PREFIX=$(wp_run config get table_prefix | tr -d '\r\n')
  [[ -n "$PREFIX" ]] || { warn "  cannot read the table prefix, skipping"; return 1; }

  UPLOADS_DIR=$(wp_run eval '$u = wp_get_upload_dir(); echo $u["basedir"];' | tr -d '\r\n')
  [[ -d "$UPLOADS_DIR" ]] || { warn "  uploads directory not found ($UPLOADS_DIR), skipping"; return 1; }

  return 0
}

# Calls <fn> once per site with the site globals set. Every site is independent:
# one failure never stops the others, which is why the script does not use -e.
for_each_site() {
  local fn="$1" cfg matched=0
  OK=(); FAILED=()

  discover_sites
  [[ ${#CONFIGS[@]} -gt 0 ]] && [[ -n "${CONFIGS[0]}" ]] || {
    warn "no WordPress installation found under $WWW_ROOT"
    return 0
  }

  for cfg in "${CONFIGS[@]}"; do
    SITE_PATH=$(dirname "$cfg")
    if [[ -n "$ONLY_SITE" && "${SITE_PATH#"$WWW_ROOT"/}" != *"$ONLY_SITE"* ]]; then
      continue
    fi
    matched=$((matched + 1))
    log ""
    log "--- ${SITE_PATH#"$WWW_ROOT"/}"
    if load_site "$cfg" && "$fn"; then
      OK+=("$SITE_NAME")
    else
      FAILED+=("${SITE_PATH#"$WWW_ROOT"/}")
    fi
  done

  # A filter that matches nothing must not look like a successful no-op:
  # the caller needs to see this as failure, not as "nothing to do".
  if [[ -n "$ONLY_SITE" && $matched -eq 0 ]]; then
    warn "--site '$ONLY_SITE' matched none of the ${#CONFIGS[@]} installations found under $WWW_ROOT"
    return 1
  fi

  return 0
}

# ---------------------------------------------------------- data collection

# One query per source rather than a single UNION: termmeta is missing on very
# old installations and a plugin can leave a table unreadable, and neither
# should cost us the whole haystack.
collect_haystack() {
  local out="$WORK/haystack.txt" q
  : > "$out"
  local -a queries=(
    "SELECT post_content FROM ${PREFIX}posts WHERE post_type <> 'attachment'"
    "SELECT post_excerpt FROM ${PREFIX}posts WHERE post_type <> 'attachment'"
    "SELECT meta_value FROM ${PREFIX}postmeta WHERE meta_key NOT IN ('_wp_attached_file','_wp_attachment_metadata','_wp_attachment_backup_sizes')"
    "SELECT option_value FROM ${PREFIX}options"
    "SELECT meta_value FROM ${PREFIX}termmeta"
    "SELECT meta_value FROM ${PREFIX}usermeta"
  )
  for q in "${queries[@]}"; do
    wp_run db query "$q" --skip-column-names >> "$out" \
      || warn "  a haystack query failed, continuing: ${q:0:60}..."
  done

  # No post_status filter above: drafts, revisions, scheduled posts and the
  # trash all count as references, which is what protects work in progress.

  if [[ $SCAN_FILES -eq 1 ]]; then
    local d
    for d in themes plugins mu-plugins; do
      [[ -d "$SITE_PATH/wp-content/$d" ]] || continue
      grep -rIohF -f "$WORK/names.txt" "$SITE_PATH/wp-content/$d" 2>/dev/null >> "$out"
    done
  fi

  [[ -s "$out" ]] || warn "  the haystack is empty: every attachment would look unused"
}

collect_inventory() {
  wp_run db query "
    SELECT p.ID, p.post_date, p.post_parent, m.meta_value
    FROM ${PREFIX}posts p
    JOIN ${PREFIX}postmeta m ON m.post_id = p.ID AND m.meta_key = '_wp_attached_file'
    WHERE p.post_type = 'attachment'
  " --skip-column-names > "$WORK/inventory.tsv"
}

# _wp_attachment_metadata is serialized PHP, which bash parses badly, so this
# is the one place the script runs PHP. It emits the authoritative map of the
# files that legitimately belong to each attachment.
collect_size_map() {
  wp_run eval '
    global $wpdb;
    $ids = $wpdb->get_col( "SELECT ID FROM {$wpdb->posts} WHERE post_type = \"attachment\"" );
    foreach ( $ids as $id ) {
      $m = wp_get_attachment_metadata( $id );
      if ( ! is_array( $m ) ) { continue; }
      if ( ! empty( $m["original_image"] ) ) {
        echo $id . "\t__original\t" . $m["original_image"] . "\n";
      }
      if ( empty( $m["sizes"] ) || ! is_array( $m["sizes"] ) ) { continue; }
      foreach ( $m["sizes"] as $name => $s ) {
        if ( empty( $s["file"] ) ) { continue; }
        echo $id . "\t" . $name . "\t" . $s["file"] . "\n";
      }
    }
  ' > "$WORK/sizemap.tsv" || warn "  cannot read the attachment metadata"
}

# Size NAMES, never dimensions. The filename carries the dimensions actually
# produced after the aspect ratio is preserved, so an uncropped 1024x1024
# "large" applied to a 1600x900 upload yields -1024x576, which appears in no
# list of registered sizes. Comparing dimensions would report almost every
# uncropped thumbnail as stale.
collect_registered_sizes() {
  wp_run media image-size --format=csv 2>/dev/null \
    | tail -n +2 | cut -d, -f1 | sed 's/^"//; s/"$//' | grep -v '^$' \
    > "$WORK/registered.txt"
  [[ -s "$WORK/registered.txt" ]] || warn "  no registered image size read, thumbnails will be left alone"
}

collect_id_set() {
  local out="$WORK/ids.txt"
  {
    # Shapes a query can pin down exactly: an ACF image field or a
    # _thumbnail_id is the bare integer, a WooCommerce gallery a comma list.
    wp_run db query "
      SELECT meta_value FROM ${PREFIX}postmeta
      WHERE meta_value REGEXP '^[0-9]+$' OR meta_value REGEXP '^[0-9]+(,[0-9]+)+$'
    " --skip-column-names | expand_id_list

    wp_run db query "
      SELECT option_value FROM ${PREFIX}options
      WHERE option_name IN ('custom_logo','site_icon','site_logo')
    " --skip-column-names | expand_id_list

    # Everything else has to be recognised by its surrounding syntax.
    extract_id_tokens < "$WORK/haystack.txt"
  } | sort -u > "$out"
}

# The pattern file grep matches the haystack against: one basename per line,
# plus its percent-encoded form when they differ.
collect_names() {
  local out="$WORK/names.txt" rel base enc
  : > "$out"
  while IFS=$'\t' read -r _ _ _ rel; do
    [[ -n "$rel" ]] || continue
    base=$(basename "$rel")
    printf '%s\n' "$base" >> "$out"
    enc=$(urlencode_name "$base")
    [[ "$enc" == "$base" ]] || printf '%s\n' "$enc" >> "$out"
  done < "$WORK/inventory.tsv"

  while IFS=$'\t' read -r _ _ fname; do
    [[ -n "$fname" ]] || continue
    printf '%s\n' "$fname" >> "$out"
    enc=$(urlencode_name "$fname")
    [[ "$enc" == "$fname" ]] || printf '%s\n' "$enc" >> "$out"
  done < "$WORK/sizemap.tsv"

  sort -u -o "$out" "$out"
}

usage() {
  # Extract header comments from shebang to first non-comment line.
  # Using awk is safer than a fixed line range, which breaks if the header
  # is edited.
  awk 'NR > 1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0"
  cat <<'EOF'

Options:
  --site <domain>      restrict to sites whose path contains <domain>
  --apply              move to quarantine (without it, report only)
  --only <class>       attachments | orphans | thumbs (default: all)
  --min-age <days>     ignore attachments newer than this (default 30)
  --keep-attached      treat post_parent <> 0 as in use
  --no-scan-files      skip the grep over themes and plugins
  --list-quarantine    list the available quarantine sets
  --restore <stamp>    restore a quarantine set (requires --site)
  -h, --help           this help

Environment overrides:
  WWW_ROOT QUARANTINE_ROOT LOG_DIR KEEP_QUARANTINE MIN_AGE_DAYS
  WP_CLI_CACHE_ROOT
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --site)            ONLY_SITE="${2:-}"; [[ -n "$ONLY_SITE" ]] || die "--site requires a value"; shift 2 ;;
      --apply)           APPLY=1; shift ;;
      --only)            ONLY_CLASS="${2:-}"; shift 2
                         case "$ONLY_CLASS" in
                           all|attachments|orphans|thumbs) ;;
                           *) die "--only takes one of: all, attachments, orphans, thumbs" ;;
                         esac ;;
      --min-age)         MIN_AGE_DAYS="${2:-}"; shift 2
                         [[ "$MIN_AGE_DAYS" =~ ^[0-9]+$ ]] || die "--min-age takes a number of days" ;;
      --keep-attached)   KEEP_ATTACHED=1; shift ;;
      --no-scan-files)   SCAN_FILES=0; shift ;;
      --list-quarantine) ACTION="list-quarantine"; shift ;;
      --restore)         ACTION="restore"; RESTORE_STAMP="${2:-}"
                         [[ -n "$RESTORE_STAMP" ]] || die "--restore requires a quarantine stamp"; shift 2 ;;
      -h|--help)         usage; exit 0 ;;
      *)                 die "unknown option: $1 (try --help)" ;;
    esac
  done

  if [[ "$ACTION" == "restore" && -z "$ONLY_SITE" ]]; then
    die "--restore also requires --site: a stamp is only unique within one site"
  fi
}

clean_site() {
  log "  prefix=$PREFIX uploads=$UPLOADS_DIR owner=$SITE_OWNER:$SITE_GROUP"
  return 0
}

main() {
  parse_args "$@"
  [[ $EUID -eq 0 ]] || die "root required (use sudo)"
  require_cmds
  mkdir -p "$LOG_DIR" "$QUARANTINE_ROOT"
  LOG_FILE="$LOG_DIR/$STAMP.log"

  case "$ACTION" in
    list-quarantine) die "not implemented yet" ;;
    restore)         die "not implemented yet" ;;
    clean)
      log "=== wp-media-clean start (apply=$APPLY, only=$ONLY_CLASS) ==="
      local site_rc=0
      for_each_site clean_site || site_rc=$?
      log ""
      log "=== done: ${#OK[@]} ok, ${#FAILED[@]} failed ==="
      [[ ${#FAILED[@]} -eq 0 ]] || warn "sites with problems: ${FAILED[*]}"
      [[ ${#FAILED[@]} -eq 0 && $site_rc -eq 0 ]]
      ;;
  esac
}

# Only run when executed, so that tests/run.sh can source this file and call
# the pure functions without triggering anything.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
