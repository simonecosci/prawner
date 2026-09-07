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

main() {
  parse_args "$@"
  [[ $EUID -eq 0 ]] || die "root required (use sudo)"
  mkdir -p "$LOG_DIR" "$QUARANTINE_ROOT"
  LOG_FILE="$LOG_DIR/$STAMP.log"
  die "not implemented yet"
}

# Only run when executed, so that tests/run.sh can source this file and call
# the pure functions without triggering anything.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
