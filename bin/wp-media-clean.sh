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

# Directory names, wherever they occur under uploads/, that belong to a
# plugin's own infrastructure rather than to media the site actually serves.
# Matched by basename at any depth, so "uploads/2024/01/elementor" and
# "uploads/elementor" are both excluded.
EXCLUDE_UPLOAD_DIRS="${EXCLUDE_UPLOAD_DIRS:-woocommerce_uploads wpforms backups wp-personal-data-exports elementor cache}"

ACTION="clean"          # clean | list-quarantine | restore
ONLY_SITE=""
ONLY_CLASS="all"        # all | attachments | orphans | thumbs
RESTORE_STAMP=""
APPLY=0
KEEP_ATTACHED=0
SCAN_FILES=1

STAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE=""

# Set by the collectors, read by classify(). Both default to "the collector
# succeeded" so that sourcing this file (the test suites do) and calling
# classify() with a hand-built $WORK never trips over an unset variable.
SIZEMAP_COMPLETE=1      # 0 when collect_size_map's output was cut short
IDS_OK=1                # 0 when one of collect_id_set's queries failed

# Out-parameters. The classify() file loop runs once per file on disk, so the
# helpers below publish their result in a global as well as printing it: a
# caller inside that loop reads the global and pays no fork, while tests/run.sh
# and every other caller keep using $(...) as before.
URLENC=""               # urlencode_name
CANON=""                # canonical_original
THUMB_BASE=""; THUMB_SIZE=""; THUMB_EXT=""   # parse_thumb_size
RELDIR=""               # rel_dir

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_dim=$'\033[2m'; c_off=$'\033[0m'

die()  { printf '%s[ERROR]%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }
warn() { printf '%s[!]%s %s\n' "$c_yel" "$c_off" "$*" >&2; [[ -n "$LOG_FILE" ]] && printf '[!] %s\n' "$*" >>"$LOG_FILE"; return 0; }
ok()   { printf '%s[ok]%s %s\n' "$c_grn" "$c_off" "$*"; }
log()  { printf '%s\n' "$*"; [[ -n "$LOG_FILE" ]] && printf '%s  %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE"; return 0; }

# ------------------------------------------------------- filename helpers
# Pure string functions. tests/run.sh sources this file and exercises them
# directly, so they must not touch global state or the filesystem.

# parse_thumb_size <filename>
# Recognises a WordPress generated size variant, "photo-800x600.jpg", and
# prints "<base>|<WxH>|<ext>". Returns 1 for anything else. The size has to sit
# at the very end of the name: "photo-800x600-detail.jpg" is a user filename
# that happens to contain digits, not a generated size.
# Also publishes $THUMB_BASE / $THUMB_SIZE / $THUMB_EXT, so the file loop can
# call it as `parse_thumb_size "$f" >/dev/null` instead of paying a subshell.
parse_thumb_size() {
  local name="$1"
  [[ "$name" =~ ^(.+)-([0-9]+x[0-9]+)\.([A-Za-z0-9]+)$ ]] || return 1
  THUMB_BASE="${BASH_REMATCH[1]}"; THUMB_SIZE="${BASH_REMATCH[2]}"; THUMB_EXT="${BASH_REMATCH[3]}"
  printf '%s|%s|%s\n' "$THUMB_BASE" "$THUMB_SIZE" "$THUMB_EXT"
}

# canonical_original <filename>
# WordPress keeps several files per upload that are not thumbnails: oversized
# uploads become "<name>-scaled.<ext>" with the untouched "<name>.<ext>" left
# on disk, and the image editor writes "<name>-e<timestamp>.<ext>" and
# "<name>-rotated.<ext>". Strips such a suffix so the caller can check whether
# the file belongs to a known upload. The six digit floor on the -e form keeps
# ordinary filenames such as "phone-e5.jpg" intact.
# Also publishes $CANON, for the same fork-free reason as parse_thumb_size.
canonical_original() {
  local name="$1"
  if [[ "$name" =~ ^(.+)-(scaled|rotated|e[0-9]{6,})\.([A-Za-z0-9]+)$ ]]; then
    CANON="${BASH_REMATCH[1]}.${BASH_REMATCH[3]}"
  else
    CANON="$name"
  fi
  printf '%s\n' "$CANON"
}

# rel_dir <path>
# The directory component of a path, normalised so that a path with no
# directory component gives "" rather than dirname's ".". Three places used to
# build this by hand (classify's doomed-attachment-files.txt, report()'s
# byte accounting and quarantine_site's thumbnail attribution) and only two of
# them normalised the ".", which put a "./" into the manifest for a root-level
# upload. Publishes $RELDIR as well as printing, and forks nothing.
rel_dir() {
  local p="$1"
  if [[ "$p" == */* ]]; then RELDIR="${p%/*}"; else RELDIR=""; fi
  printf '%s\n' "$RELDIR"
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
  URLENC="$out"
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
#
# classify() loads used-names.txt into $USED_NAMES_MAP once and sets
# $USED_NAMES_LOADED; the lookup is then a hash hit rather than a grep that
# rescans the whole file, and the encoded spelling costs no subshell either
# (urlencode_name publishes $URLENC). The grep path is kept for callers that
# have a used-names.txt and no map - tests/run.sh is one.
declare -A USED_NAMES_MAP=()
USED_NAMES_LOADED=0

name_is_used() {
  local n="$1"
  if [[ $USED_NAMES_LOADED -eq 1 ]]; then
    [[ -n "${USED_NAMES_MAP[$n]+x}" ]] && return 0
    urlencode_name "$n" >/dev/null
    [[ "$URLENC" != "$n" && -n "${USED_NAMES_MAP[$URLENC]+x}" ]]
    return
  fi
  grep -qxF "$n" "$WORK/used-names.txt" && return 0
  local enc; enc=$(urlencode_name "$n")
  [[ "$enc" != "$n" ]] && grep -qxF "$enc" "$WORK/used-names.txt"
}

# ------------------------------------------------------------- wp plumbing

# mysqldump is in the list because `wp db export` shells out to it: without it
# every row dump comes back empty, the dump gate refuses, and the whole
# attachments class is skipped on every run - visible only as a runtime warn
# buried in the log. comm is deliberately NOT in the list: the set difference
# it was meant for is done with grep -qxF and an associative array, and
# requiring a command the script never invokes turns a working VPS away.
require_cmds() {
  local missing=() c
  for c in wp mysql mysqldump grep sed awk sort find stat sudo; do
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

  # qmove records a quarantined file under "${src#$SITE_PATH/}", and
  # restore_site puts it back at "$SITE_PATH/$rel". That is only a round trip
  # while the uploads directory really is under the docroot as a string. An
  # UPLOADS define pointing outside it, a shared multisite uploads directory
  # or a symlinked release directory leaves the strip unmatched, $rel absolute,
  # the file quarantined under files//var/www/... and restored to
  # "$SITE_PATH//var/www/..." - a path mkdir -p creates without complaint,
  # under an "[ok] restored" the operator has no reason to doubt. The check is
  # textual on purpose: it is exactly the operation qmove performs.
  [[ "$UPLOADS_DIR" == "$SITE_PATH"/* ]] || {
    warn "  the uploads directory ($UPLOADS_DIR) is not inside the docroot ($SITE_PATH): quarantined paths would not be relative to the site and a restore would put them back in the wrong place, skipping"
    return 1
  }

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
#
# Which failures are survivable is not a detail: a query that fails silently
# strips references out of the haystack, and a missing reference is a false
# "orphan" - the one direction every heuristic here is forbidden to err in.
# posts, postmeta and options carry essentially every reference on a normal
# site, so losing one of them is fatal for the site (return 1, the site is
# reported as failed and nothing is classified). termmeta and usermeta are the
# two that are genuinely optional - termmeta is missing on very old
# installations - and only those two keep the warn-and-continue behaviour that
# splitting the UNION into six queries was for.
collect_haystack() {
  local out="$WORK/haystack.txt" i rc=0
  : > "$out"
  local -a queries=(
    "SELECT post_content FROM ${PREFIX}posts WHERE post_type <> 'attachment'"
    "SELECT post_excerpt FROM ${PREFIX}posts WHERE post_type <> 'attachment'"
    "SELECT meta_value FROM ${PREFIX}postmeta WHERE meta_key NOT IN ('_wp_attached_file','_wp_attachment_metadata','_wp_attachment_backup_sizes')"
    "SELECT option_value FROM ${PREFIX}options"
    "SELECT meta_value FROM ${PREFIX}termmeta"
    "SELECT meta_value FROM ${PREFIX}usermeta"
  )
  # Same order as the array above: posts, posts, postmeta, options are
  # required; termmeta and usermeta are not.
  local -a required=(1 1 1 1 0 0)
  for i in "${!queries[@]}"; do
    wp_run db query "${queries[i]}" --skip-column-names >> "$out" && continue
    if [[ "${required[i]}" -eq 1 ]]; then
      warn "  a required haystack query failed, the haystack would be missing references: ${queries[i]:0:60}..."
      rc=1
    else
      warn "  an optional haystack query failed, continuing: ${queries[i]:0:60}..."
    fi
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
  return $rc
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
#
# _wp_attachment_backup_sizes is read too: after a crop or rotate, the edited
# image becomes the attached file and the pre-edit original plus its old
# generated sizes survive only in this meta key, under WordPress's own
# "Restore original image" feature. Emitted under the __backup pseudo size so
# classify() never treats them as stale.
#
# A 4th column carries the attachment's own subdirectory under the uploads
# basedir (dirname of _wp_attached_file, empty for a root-level upload).
# sizemap.tsv carries no directory in column 3, its filename column, so two
# attachments that happen to generate a same-named size in different months
# are otherwise indistinguishable; the thumbnail-attribution lookup in
# quarantine_site matches on this column too so it cannot pick the wrong one.
#
# The eval loops get_post_meta() over every attachment on the site, so on a
# large library with a low memory_limit or max_execution_time it can die
# partway and still exit 0, leaving a PARTIAL map - which silently dooms the
# thumbnails of every attachment after the point of death. A partial map is
# indistinguishable from a complete one by inspection, so the PHP prints a
# terminator after the loop: if the last line of the output is not that
# terminator, the dump was cut short. That is exact rather than heuristic - no
# row count against the attachment count, which cannot tell a truncated map
# from a library of PDFs that legitimately generate no sizes.
SIZEMAP_MARKER="__SIZEMAP_COMPLETE__"

collect_size_map() {
  local raw="$WORK/sizemap.raw"
  SIZEMAP_COMPLETE=0
  wp_run eval '
    global $wpdb;
    $ids = $wpdb->get_col( "SELECT ID FROM {$wpdb->posts} WHERE post_type = \"attachment\"" );
    foreach ( $ids as $id ) {
      $attached = get_post_meta( $id, "_wp_attached_file", true );
      $dir = $attached ? dirname( $attached ) : "";
      if ( $dir === "." ) { $dir = ""; }
      $m = wp_get_attachment_metadata( $id );
      if ( is_array( $m ) && ! empty( $m["original_image"] ) ) {
        echo $id . "\t__original\t" . $m["original_image"] . "\t" . $dir . "\n";
      }
      $backup = get_post_meta( $id, "_wp_attachment_backup_sizes", true );
      if ( is_array( $backup ) ) {
        foreach ( $backup as $b ) {
          if ( ! empty( $b["file"] ) ) {
            echo $id . "\t__backup\t" . $b["file"] . "\t" . $dir . "\n";
          }
        }
      }
      if ( ! is_array( $m ) || empty( $m["sizes"] ) || ! is_array( $m["sizes"] ) ) { continue; }
      foreach ( $m["sizes"] as $name => $s ) {
        if ( empty( $s["file"] ) ) { continue; }
        echo $id . "\t" . $name . "\t" . $s["file"] . "\t" . $dir . "\n";
      }
    }
    echo "__SIZEMAP_COMPLETE__\n";
  ' > "$raw" || warn "  cannot read the attachment metadata"

  if [[ -s "$raw" ]] && [[ "$(tail -n 1 "$raw")" == "$SIZEMAP_MARKER" ]]; then
    SIZEMAP_COMPLETE=1
  else
    warn "  the attachment size map is truncated (no completion marker): PHP probably ran out of memory or time. The site is refused this run - a partial size map makes every size of every attachment past the cut look like a forgotten leftover, and the untouched original of every -scaled upload past the cut look like an orphan."
  fi
  grep -vxF "$SIZEMAP_MARKER" "$raw" > "$WORK/sizemap.tsv"
  return 0
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

# ids.txt is the ONLY defence a bare-integer reference has: a _thumbnail_id or
# an ACF image field never names its file anywhere in the haystack. classify()
# already refuses to run the attachments class on an empty ids.txt - but that
# guard does not fire when one of the two queries below fails and the other
# still fills the file, which is the more likely failure and the more dangerous
# one: the set comes back plausible and short, and every featured image whose
# ID was in the missing half is reported as unused. Each query is therefore
# checked on its own and $IDS_OK records the answer.
#
# Written to intermediate files rather than piped into one group: a `{ ... } |
# sort` group runs in a subshell, so any flag set inside it is lost.
collect_id_set() {
  local out="$WORK/ids.txt" raw="$WORK/ids-raw.txt"
  IDS_OK=1
  : > "$raw"

  # Shapes a query can pin down exactly: an ACF image field or a
  # _thumbnail_id is the bare integer, a WooCommerce gallery a comma list.
  if wp_run db query "
      SELECT meta_value FROM ${PREFIX}postmeta
      WHERE meta_value REGEXP '^[0-9]+$' OR meta_value REGEXP '^[0-9]+(,[0-9]+)+$'
    " --skip-column-names > "$WORK/ids-postmeta.txt"; then
    expand_id_list < "$WORK/ids-postmeta.txt" >> "$raw"
  else
    IDS_OK=0
    warn "  the postmeta ID query failed: featured images and ACF fields would look unreferenced"
  fi

  if wp_run db query "
      SELECT option_value FROM ${PREFIX}options
      WHERE option_name IN ('custom_logo','site_icon','site_logo')
    " --skip-column-names > "$WORK/ids-options.txt"; then
    expand_id_list < "$WORK/ids-options.txt" >> "$raw"
  else
    IDS_OK=0
    warn "  the options ID query failed: the site logo and favicon would look unreferenced"
  fi

  # Everything else has to be recognised by its surrounding syntax.
  extract_id_tokens < "$WORK/haystack.txt" >> "$raw"

  sort -u "$raw" > "$out"
  return 0
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

  while IFS=$'\t' read -r _ _ fname _; do
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
  --list-quarantine    list the available quarantine sets (needs a loadable
                       site: wp-cli must reach the database, so a site whose
                       DB is down will not show its quarantine sets here)
  --restore <stamp>    restore a quarantine set (requires --site)
  -h, --help           this help

Environment overrides:
  WWW_ROOT QUARANTINE_ROOT LOG_DIR KEEP_QUARANTINE MIN_AGE_DAYS
  WP_CLI_CACHE_ROOT EXCLUDE_UPLOAD_DIRS
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
                         [[ -n "$RESTORE_STAMP" ]] || die "--restore requires a quarantine stamp"
                         # Interpolated straight into a path under QUARANTINE_ROOT while
                         # running as root: anything other than the stamp format
                         # quarantine_site itself generates (date +%Y%m%d-%H%M%S) is
                         # rejected outright, rather than letting something like
                         # "../../etc" escape the site's own quarantine directory.
                         [[ "$RESTORE_STAMP" =~ ^[0-9]{8}-[0-9]{6}$ ]] \
                           || die "--restore takes a quarantine stamp of the form YYYYMMDD-HHMMSS (got: $RESTORE_STAMP)"
                         shift 2 ;;
      -h|--help)         usage; exit 0 ;;
      *)                 die "unknown option: $1 (try --help)" ;;
    esac
  done

  if [[ "$ACTION" == "restore" && -z "$ONLY_SITE" ]]; then
    die "--restore also requires --site: a stamp is only unique within one site"
  fi

  # KEEP_QUARANTINE only ever comes from the environment (no --flag for it),
  # but it still needs validating before prune_quarantine does arithmetic
  # with it: a non-numeric value errors out the $(( )) below, and 0 means
  # "keep nothing", which deletes the quarantine set this very run just
  # created, seconds after the files landed in it. Checked after the loop, not
  # before it, so --help (which exits inside the loop) still works with a bad
  # KEEP_QUARANTINE in the environment instead of dying on it first.
  [[ "$KEEP_QUARANTINE" =~ ^[0-9]+$ && "$KEEP_QUARANTINE" -ge 1 ]] \
    || die "KEEP_QUARANTINE must be an integer >= 1 (got: $KEEP_QUARANTINE)"
}

# -------------------------------------------------------------- classify

# Prints the names that the haystack does mention. A single grep -F -f pass:
# GNU grep compiles the pattern file into an Aho-Corasick automaton, so
# thousands of filenames cost one scan of the haystack, not one scan each.
used_names() {
  grep -oF -f "$WORK/names.txt" "$WORK/haystack.txt" 2>/dev/null | sort -u
}

classify() {
  used_names > "$WORK/used-names.txt"

  # One pass over used-names.txt into a hash, instead of a grep that rescans
  # the whole file once (twice, for a name whose encoded spelling differs) per
  # candidate. name_is_used() reads the map when $USED_NAMES_LOADED is 1.
  # Rebuilt from scratch on every call: classify() runs once per site.
  USED_NAMES_MAP=()
  USED_NAMES_LOADED=0
  local k
  while IFS= read -r k; do
    [[ -n "$k" ]] && USED_NAMES_MAP["$k"]=1
  done < "$WORK/used-names.txt"
  USED_NAMES_LOADED=1

  : > "$WORK/doomed-attachments.tsv"
  : > "$WORK/doomed-orphans.txt"
  : > "$WORK/doomed-thumbs.txt"
  : > "$WORK/doomed-attachment-files.txt"

  # sizemap.tsv is not one class's input, it is the site's. Both
  # known-files.txt and names.txt are built from it, and those two feed every
  # remaining class: the orphans branch asks known-files.txt "does WordPress
  # know this file?", and used-names.txt - the protection every file has -
  # comes from grepping the haystack with names.txt. So a size map the
  # collector could not be trusted to finish cannot be handled by skipping one
  # class. A WordPress 5.3+ oversized upload is the clearest case: the attached
  # file is "photo-scaled.jpg" and the untouched "photo.jpg" exists on disk
  # only as the map's __original row, so with the map missing neither
  # "photo.jpg" nor any of its generated sizes is a known file,
  # canonical_original cannot help (it strips -scaled, and the name on disk
  # carries no suffix), and the whole set lands in doomed-orphans.txt - live
  # images, reported as orphans, under an exit status of 0.
  #
  # Untrustworthy therefore means fatal for the site, exactly as a failed
  # required haystack query is: clean_site turns this into the same refusal,
  # the site is reported as FAILED and the run exits non-zero.
  #
  # $SIZEMAP_COMPLETE is the whole of the test, and it is exact rather than
  # heuristic: collect_size_map's PHP prints a terminator after its loop, so
  # the marker is present if and only if the dump ran to the end. Emptiness
  # only chooses the wording - an operator needs to know whether the collector
  # produced nothing at all or died partway. An empty map that DID emit its
  # marker is the legitimate "this library generates no sizes" case and is not
  # refused; the class-level guard further down still skips the thumbs class
  # for it.
  if [[ $SIZEMAP_COMPLETE -eq 0 ]]; then
    if [[ -s "$WORK/sizemap.tsv" ]]; then
      warn "  refusing to classify: the size map is incomplete (the collector emitted no completion marker), and both known-files.txt and names.txt are built from it, so every class would see live files as unknown"
    else
      warn "  refusing to classify: the size map is empty and the collector emitted no completion marker, and both known-files.txt and names.txt are built from it, so every class would see live files as unknown"
    fi
    return 1
  fi

  local cutoff
  cutoff=$(date -d "-${MIN_AGE_DAYS} days" '+%Y-%m-%d %H:%M:%S')

  # --- attachments
  # A bare integer such as _thumbnail_id or an ACF image field never appears
  # in the haystack by name: ids.txt is its only defence. An empty ids.txt
  # means the query that built it failed, not that nothing is referenced, so
  # trusting it here would doom every old featured image on the site.
  if [[ "$ONLY_CLASS" == "all" || "$ONLY_CLASS" == "attachments" ]]; then
    if [[ ! -s "$WORK/ids.txt" ]]; then
      warn "  ids.txt is empty, skipping the attachments class this run"
    elif [[ $IDS_OK -eq 0 ]]; then
      # A non-empty ids.txt built from only some of its queries is worse than
      # an empty one: it looks like a real answer. collect_id_set says so.
      warn "  one of the ID queries failed, so ids.txt is incomplete: skipping the attachments class this run"
    else
      local id pdate parent rel base
      while IFS=$'\t' read -r id pdate parent rel; do
        [[ -n "$id" ]] || continue
        [[ "$pdate" < "$cutoff" ]] || continue
        [[ $KEEP_ATTACHED -eq 0 || "$parent" == "0" ]] || continue
        base="${rel##*/}"
        name_is_used "$base" && continue
        grep -qxF "$id" "$WORK/ids.txt" && continue
        printf '%s\t%s\n' "$id" "$rel" >> "$WORK/doomed-attachments.tsv"
      done < "$WORK/inventory.tsv"
    fi
  fi

  # Every file report() will already charge to a doomed attachment (its own
  # attached file, plus every size sizemap.tsv lists for that ID), as paths
  # relative to $UPLOADS_DIR. The file loop below skips these: without it, a
  # deregistered thumbnail of a doomed attachment would double-count its
  # bytes and hand Task 7 the same path in two doomed lists.
  if [[ -s "$WORK/doomed-attachments.tsv" ]]; then
    local id rel dir
    while IFS=$'\t' read -r id rel; do
      printf '%s\n' "$rel" >> "$WORK/doomed-attachment-files.txt"
      # rel_dir gives "" rather than dirname's "." for a root-level upload
      # (uploads_use_yearmonth_folders off), so the entry has no "./" prefix
      # and matches $relf below exactly. The prefix is passed to awk as a
      # variable rather than spliced into a sed replacement, so a directory
      # name containing "|" or "&" is applied literally instead of being read
      # as sed syntax.
      rel_dir "$rel" >/dev/null; dir="$RELDIR"
      awk -F'\t' -v i="$id" -v pre="${dir:+$dir/}" '$1 == i { print pre $3 }' "$WORK/sizemap.tsv" \
        >> "$WORK/doomed-attachment-files.txt"
    done < "$WORK/doomed-attachments.tsv"
    sort -u -o "$WORK/doomed-attachment-files.txt" "$WORK/doomed-attachment-files.txt"
  fi

  # --- files on disk
  # Everything that legitimately belongs to an attachment, as bare filenames.
  # sed rather than `xargs basename`: uploads with spaces in the name are
  # common and xargs would split them into pieces.
  sed 's|.*/||' < <(cut -f4 "$WORK/inventory.tsv") | sort -u > "$WORK/known-files.txt"
  cut -f3 "$WORK/sizemap.tsv"   | sort -u >> "$WORK/known-files.txt"
  sort -u -o "$WORK/known-files.txt" "$WORK/known-files.txt"

  # Size names still registered, plus the pseudo names for the untouched
  # original of a -scaled upload and for a pre-edit backup size, neither of
  # which is ever a stale thumbnail. A registered.txt that came back empty
  # means the size-listing query failed, not that no size is registered, so
  # the whole thumbs class is skipped rather than trusting an empty list.
  local thumbs_ok=1
  if [[ -s "$WORK/registered.txt" ]]; then
    cp "$WORK/registered.txt" "$WORK/live-sizes.txt"
  else
    thumbs_ok=0
    : > "$WORK/live-sizes.txt"
    warn "  registered.txt is empty, skipping the thumbs class this run"
  fi
  printf '__original\n__backup\n' >> "$WORK/live-sizes.txt"

  # A size map that emitted its completion marker but is still empty is the one
  # trustworthy way of being empty: the library genuinely generates no sizes
  # (PDFs, SVGs, audio). The site is not refused for it - the refusal above
  # deliberately does not fire - but the thumbs class is still skipped, because
  # with no size map row anywhere every "photo-150x150.jpg" on disk would reach
  # the "forgotten generated size" branch below, where parse_thumb_size reduces
  # it to "photo.jpg", which IS known, and the whole site's thumbnails would be
  # classified as stale. Under --apply that moves the lot, leaves
  # thumb-sizes.tsv empty so the metadata is never updated, and 404s every
  # srcset and every the_post_thumbnail() on the site. Skipping the class costs
  # nothing but a run.
  if [[ -s "$WORK/inventory.tsv" && ! -s "$WORK/sizemap.tsv" ]]; then
    thumbs_ok=0
    warn "  the size map is empty while the site has attachments, skipping the thumbs class this run: without it every generated size on the site looks stale"
  fi

  # --only attachments produces nothing from the disk sweep - every branch
  # below writes to doomed-orphans.txt or doomed-thumbs.txt - so on a 200k file
  # tree it is a walk of the entire uploads directory for no output at all.
  if [[ "$ONLY_CLASS" == "attachments" ]]; then
    return 0
  fi

  local f relf fname
  local -a prune_names
  read -ra prune_names <<< "$EXCLUDE_UPLOAD_DIRS"
  local -a find_cmd=(find "$UPLOADS_DIR")
  if [[ ${#prune_names[@]} -gt 0 ]]; then
    local -a name_or=() n
    for n in "${prune_names[@]}"; do
      [[ ${#name_or[@]} -eq 0 ]] || name_or+=(-o)
      name_or+=(-name "$n")
    done
    find_cmd+=(-type d \( "${name_or[@]}" \) -prune -o)
  fi
  find_cmd+=(-type f -print)

  # Everything the loop needs to ask a question of, hashed once. What this
  # replaces, per file: a basename fork, one or two greps inside name_is_used,
  # a grep over doomed-attachment-files.txt, a grep over known-files.txt, two
  # command substitutions, and on the thumbs branch an awk, a sort and another
  # grep - each of those greps rescanning its whole file. That is O(files x
  # known) with five to eight forks a file, which is hours on a large tree and
  # many minutes on a routine one; used_names() goes to the trouble of being a
  # single Aho-Corasick pass and the loop right below it threw that away.
  #
  # No decision changes: every lookup below is the same question the grep asked
  # (an exact whole-line match against the same file), and the two parse
  # helpers are the same [[ =~ ]] they always were - only the $(...) around
  # them is gone.
  local -A known_map=() doomed_map=() live_map=() file_has_size=() file_live=()
  while IFS= read -r k; do
    [[ -n "$k" ]] && known_map["$k"]=1
  done < "$WORK/known-files.txt"
  while IFS= read -r k; do
    [[ -n "$k" ]] && doomed_map["$k"]=1
  done < "$WORK/doomed-attachment-files.txt"
  while IFS= read -r k; do
    [[ -n "$k" ]] && live_map["$k"]=1
  done < "$WORK/live-sizes.txt"

  # filename -> "has at least one size name" and "has at least one LIVE size
  # name", which is all the thumbs branch ever asked file-to-size.tsv. A single
  # file can be shared by two registered sizes with identical dimensions, so
  # one filename can carry several rows here and any single live one keeps it.
  local smname smfile
  while IFS=$'\t' read -r _ smname smfile _; do
    [[ -n "$smfile" ]] || continue
    file_has_size["$smfile"]=1
    [[ -n "${live_map[$smname]+x}" ]] && file_live["$smfile"]=1
  done < "$WORK/sizemap.tsv"

  # A silent walk of a large uploads tree is indistinguishable from a hang.
  local n_scanned=0
  log "  scanning $UPLOADS_DIR"

  while IFS= read -r f; do
    n_scanned=$((n_scanned + 1))
    fname="${f##*/}"

    # WordPress's own infrastructure files, never media: the index.php every
    # uploads/ directory ships with, and dotfiles such as the .htaccess that
    # keeps WooCommerce downloadable products from being served directly.
    case "$fname" in
      index.php|index.html|index.htm|web.config|.*) continue ;;
    esac

    # Referenced by name anywhere? Then it stays, whatever it is. This is what
    # protects srcset candidates for sizes that are no longer registered.
    name_is_used "$fname" && continue

    relf="${f#"$UPLOADS_DIR"/}"
    [[ -n "${doomed_map[$relf]+x}" ]] && continue

    if [[ -n "${known_map[$fname]+x}" ]]; then
      # Known to WordPress. Only a thumbnail stored under a size name that is
      # no longer registered can go -- and only when every size name mapped
      # to this filename is dead, since two live sizes with identical
      # dimensions collapse onto the same file.
      [[ $thumbs_ok -eq 1 ]] || continue
      [[ "$ONLY_CLASS" == "all" || "$ONLY_CLASS" == "thumbs" ]] || continue
      parse_thumb_size "$fname" >/dev/null || continue
      [[ -n "${file_has_size[$fname]+x}" ]] || continue
      [[ -n "${file_live[$fname]+x}" ]] && continue
      printf '%s\n' "$f" >> "$WORK/doomed-thumbs.txt"
      continue
    fi

    # Unknown to WordPress. A -scaled / -rotated / -e<timestamp> variant of a
    # known upload is not an orphan.
    canonical_original "$fname" >/dev/null
    if [[ "$CANON" != "$fname" ]] && [[ -n "${known_map[$CANON]+x}" ]]; then
      continue
    fi

    # A generated size of a live attachment that the metadata has forgotten:
    # a leftover from an earlier regeneration.
    if parse_thumb_size "$fname" >/dev/null; then
      if [[ -n "${known_map[$THUMB_BASE.$THUMB_EXT]+x}" ]]; then
        [[ $thumbs_ok -eq 1 ]] || continue
        [[ "$ONLY_CLASS" == "all" || "$ONLY_CLASS" == "thumbs" ]] || continue
        printf '%s\n' "$f" >> "$WORK/doomed-thumbs.txt"
        continue
      fi
    fi

    [[ "$ONLY_CLASS" == "all" || "$ONLY_CLASS" == "orphans" ]] || continue
    printf '%s\n' "$f" >> "$WORK/doomed-orphans.txt"
  done < <("${find_cmd[@]}" 2>/dev/null)

  log "  scanned $n_scanned files under uploads"
  return 0
}

# ---------------------------------------------------------------- report

# Total bytes of the paths listed on stdin.
bytes_of() {
  local total=0 f sz
  while IFS= read -r f; do
    sz=$(stat -c %s "$f" 2>/dev/null) || continue
    total=$((total + sz))
  done
  printf '%s\n' "$total"
}

human() { numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || printf '%sB\n' "${1:-0}"; }

report() {
  local n_att n_orph n_thumb b_att b_orph b_thumb

  n_att=$(wc -l < "$WORK/doomed-attachments.tsv")
  n_orph=$(wc -l < "$WORK/doomed-orphans.txt")
  n_thumb=$(wc -l < "$WORK/doomed-thumbs.txt")

  # An attachment costs its original plus every generated size.
  cut -f2 "$WORK/doomed-attachments.tsv" \
    | sed "s|^|$UPLOADS_DIR/|" > "$WORK/att-files.txt"
  local id rel dir
  while IFS=$'\t' read -r id rel; do
    # Same root-level case as classify()'s doomed-attachment-files.txt:
    # rel_dir drops the "." dirname gives for an upload with no directory
    # component, so the two agree on which files exist under a doomed
    # attachment.
    rel_dir "$rel" >/dev/null; dir="$RELDIR"
    awk -F'\t' -v i="$id" '$1 == i { print $3 }' "$WORK/sizemap.tsv" \
      | sed "s|^|$UPLOADS_DIR/${dir:+$dir/}|" >> "$WORK/att-files.txt"
  done < "$WORK/doomed-attachments.tsv"

  b_att=$(bytes_of   < "$WORK/att-files.txt")
  b_orph=$(bytes_of  < "$WORK/doomed-orphans.txt")
  b_thumb=$(bytes_of < "$WORK/doomed-thumbs.txt")

  log "  attachments: $n_att ($(human "$b_att"))"
  log "  orphan files: $n_orph ($(human "$b_orph"))"
  log "  stale thumbs: $n_thumb ($(human "$b_thumb"))"
  log "  reclaimable: $(human $((b_att + b_orph + b_thumb)))"

  # The console shows a sample; the log keeps the lot.
  {
    printf '\n--- attachments\n'; cat "$WORK/doomed-attachments.tsv"
    printf '\n--- orphan files\n'; cat "$WORK/doomed-orphans.txt"
    printf '\n--- stale thumbs\n'; cat "$WORK/doomed-thumbs.txt"
  } >> "$LOG_FILE"

  if [[ $APPLY -eq 0 ]]; then
    # One sample per class, labelled, all three in the same form. The thumbs
    # class used to be missing here altogether - usually the largest count and
    # the class where an operator most wants to eyeball what is about to move -
    # and the two that were printed were run together with no labels in two
    # different path forms, one relative to the uploads directory and one
    # absolute. Absolute for all three: it is the form an operator can paste
    # into ls or stat without first working out what it is relative to.
    sample_class "attachments" "$n_att"   "$WORK/doomed-attachments.tsv"  tsv
    sample_class "orphan files" "$n_orph" "$WORK/doomed-orphans.txt"      abs
    sample_class "stale thumbs" "$n_thumb" "$WORK/doomed-thumbs.txt"      abs
    printf '  %sfull list in %s%s\n' "$c_dim" "$LOG_FILE" "$c_off"
  fi
}

# sample_class <label> <count> <file> <tsv|abs>
# Up to five paths from one doomed list, as absolute paths. "tsv" reads column
# 2 of doomed-attachments.tsv, which is relative to the uploads directory;
# "abs" reads a plain list that is already absolute.
sample_class() {
  local label="$1" n="$2" file="$3" form="$4" line
  if [[ "$n" -eq 0 ]]; then
    printf '    %s: none\n' "$label"
    return 0
  fi
  printf '    %s (first %s of %s):\n' "$label" "$(( n < 5 ? n : 5 ))" "$n"
  if [[ "$form" == "tsv" ]]; then
    cut -f2 "$file" | head -5 | while IFS= read -r line; do
      printf '      %s/%s\n' "${UPLOADS_DIR%/}" "$line"
    done
  else
    head -5 "$file" | while IFS= read -r line; do
      printf '      %s\n' "$line"
    done
  fi
}

# ------------------------------------------------------------- per site

clean_site() {
  WORK=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$WORK'" RETURN

  collect_inventory
  collect_size_map
  collect_registered_sizes
  collect_names
  local haystack_ok=1
  collect_haystack || haystack_ok=0
  collect_id_set

  # A haystack missing one of its required sources is not a smaller haystack,
  # it is a haystack with references removed from it, and every reference it
  # lost turns some file into a false orphan. Nothing is classified from it.
  if [[ $haystack_ok -eq 0 ]]; then
    warn "  refusing to classify: the haystack is missing at least one required source"
    return 1
  fi

  if [[ ! -s "$WORK/inventory.tsv" ]]; then
    log "  no attachment found, nothing to do"
    return 0
  fi
  if [[ ! -s "$WORK/haystack.txt" ]]; then
    warn "  refusing to classify with an empty haystack"
    return 1
  fi

  # classify() refuses the site outright when a collector its output cannot be
  # separated from came back untrustworthy - today that is the size map, which
  # feeds known-files.txt and names.txt and so every class. Same treatment as
  # the two haystack refusals above: nothing is reported, nothing is moved, the
  # site lands in FAILED and the run exits non-zero.
  classify || return 1
  report

  [[ $APPLY -eq 1 ]] || return 0
  quarantine_site
}

# ------------------------------------------------------------ quarantine

# Moves one file into the quarantine, keeping its path relative to the docroot
# so that --restore is a plain move back.
qmove() {
  local src="$1" class="$2" att="$3" rel dest
  # A path that reaches qmove a second time in the same run (a stale thumb
  # that is also a size of a doomed attachment, say) has no source left the
  # second time around: without this check, "dest exists and src is gone"
  # below cannot tell that apart from a genuine no-clobber skip, and would
  # record a manifest line for a file that never moved on this call.
  [[ -e "$src" ]] || { warn "  missing, not moved: $src"; return 1; }
  rel="${src#"$SITE_PATH"/}"
  dest="$QDIR/files/$rel"
  mkdir -p "$(dirname "$dest")"
  # mv -n exits 0 even when it silently skips an existing destination (GNU
  # coreutils), so the exit status alone cannot tell a real move from a
  # no-clobber skip. Check the filesystem instead: the move only actually
  # happened if the source is gone and the destination is there.
  mv -n "$src" "$dest" 2>>"$LOG_FILE"
  if [[ -e "$dest" && ! -e "$src" ]]; then
    printf '%s\t%s\t%s\n' "$class" "$rel" "$att" >> "$QDIR/manifest.tsv"
    return 0
  fi
  warn "  cannot move $src"
  return 1
}

prune_quarantine() {
  local site_dir="$QUARANTINE_ROOT/$SITE_SLUG" old
  [[ -d "$site_dir" ]] || return 0
  ls -1dt "$site_dir"/*/ 2>/dev/null | tail -n +$((KEEP_QUARANTINE + 1)) | while read -r old; do
    # Belt and braces: never remove the set this very run just created, no
    # matter what KEEP_QUARANTINE computes to. This is the only code path in
    # the whole program that deletes anything for real.
    [[ "${old%/}" == "$QDIR" ]] && continue
    log "  pruning old quarantine set: $old"
    rm -rf "$old"
  done
}

# Every exit from this function used to be `return 0`, so a run in which the
# dump gate refused, or every move failed, or every `wp post delete` failed,
# still put the site in OK, still printed "=== done: N ok, 0 failed ===" and
# still exited 0. $rc is what makes the spec's "exit status is non-zero if any
# site failed" true for the half of the program that actually moves files:
# anything that did not happen but was supposed to sets it, and the return
# carries it up through clean_site to main.
quarantine_site() {
  QDIR="$QUARANTINE_ROOT/$SITE_SLUG/$STAMP"
  local rc=0

  if ! mkdir -p "$QDIR/files" "$QDIR/rows" 2>>"$LOG_FILE"; then
    warn "  cannot create the quarantine directory $QDIR, nothing was moved"
    return 1
  fi
  if ! : > "$QDIR/manifest.tsv"; then
    warn "  cannot write the quarantine manifest $QDIR/manifest.tsv, nothing was moved"
    return 1
  fi

  local ids id rel dir fname f sname move_ok n_att_done
  local has_rows_posts has_rows_postmeta footer_posts footer_postmeta dump_ok
  local thumb_ids thumb_dir n_orph_done n_thumb_done

  # --- attachments. Order matters: dump the rows, then move the files, then
  # let WordPress delete the post. Deleting first would take the files with it;
  # moving first leaves wp_delete_attachment nothing to unlink, and it still
  # cleans up postmeta and the term relationships correctly.
  if [[ -s "$WORK/doomed-attachments.tsv" ]]; then
    ids=$(cut -f1 "$WORK/doomed-attachments.tsv" | paste -sd, -)

    wp_run db export - --tables="${PREFIX}posts" --where="ID IN ($ids)" \
      --no-create-info --skip-add-drop-table > "$QDIR/rows/posts.sql"
    wp_run db export - --tables="${PREFIX}postmeta" --where="post_id IN ($ids)" \
      --no-create-info --skip-add-drop-table > "$QDIR/rows/postmeta.sql"

    # The exit status of wp_run is not the test here: a dump that fails partway
    # can still exit 0 and leave a truncated file. Non-empty is necessary but
    # not sufficient either: mysqldump writes a comment header before any row,
    # so a dump that dies right after the header is non-empty and would pass
    # a plain -s test while carrying zero rows.
    #
    # Two independent checks, both required: at least one INSERT INTO in each
    # dump (no rows captured is refused outright), and, if wp db export emits
    # a "-- Dump completed" footer, it must be present in both dumps or in
    # neither (present in only one means that one was cut short). If neither
    # dump carries the footer, this build of wp-cli/mysqldump does not emit
    # it, so that check is skipped and only the INSERT test gates the removal.
    dump_ok=0
    if [[ ! -s "$QDIR/rows/posts.sql" || ! -s "$QDIR/rows/postmeta.sql" ]]; then
      warn "  the row dump failed or is empty: attachments left untouched"
      rc=1
    else
      grep -q '^INSERT INTO' "$QDIR/rows/posts.sql"    && has_rows_posts=1    || has_rows_posts=0
      grep -q '^INSERT INTO' "$QDIR/rows/postmeta.sql" && has_rows_postmeta=1 || has_rows_postmeta=0
      grep -q -- '-- Dump completed' "$QDIR/rows/posts.sql"    && footer_posts=1    || footer_posts=0
      grep -q -- '-- Dump completed' "$QDIR/rows/postmeta.sql" && footer_postmeta=1 || footer_postmeta=0

      if [[ $has_rows_posts -eq 0 || $has_rows_postmeta -eq 0 ]]; then
        warn "  the row dump captured no rows: attachments left untouched"
        rc=1
      elif [[ $footer_posts -ne $footer_postmeta ]]; then
        warn "  one row dump looks truncated (completion footer in one but not the other): attachments left untouched"
        rc=1
      else
        [[ $footer_posts -eq 0 ]] && warn "  wp db export does not emit a completion footer here, proceeding on the INSERT check alone"
        dump_ok=1
      fi
    fi

    if [[ $dump_ok -eq 1 ]]; then
      n_att_done=0
      while IFS=$'\t' read -r id rel; do
        rel_dir "$rel" >/dev/null; dir="$RELDIR"
        move_ok=1
        qmove "$UPLOADS_DIR/$rel" attachment "$id" || move_ok=0
        # every generated size of this attachment. "${dir:+$dir/}" rather than
        # "$dir/": for a root-level upload $dir is empty, and the plain form
        # would build ".../uploads//photo-150x150.jpg" - which opens the file
        # perfectly well and then records that doubled slash in the manifest,
        # where restore_chown_path would resolve its dirname to $UPLOADS_DIR
        # itself and chown the uploads directory. Same normalisation as
        # classify() and report(), from the same helper.
        while IFS= read -r fname; do
          if [[ -f "$UPLOADS_DIR/${dir:+$dir/}$fname" ]]; then
            qmove "$UPLOADS_DIR/${dir:+$dir/}$fname" attachment "$id" || move_ok=0
          fi
        done < <(awk -F'\t' -v i="$id" '$1 == i { print $3 }' "$WORK/sizemap.tsv")
        # A file that failed to move is still on disk and the row is still
        # the only record of it; deleting the post here would leave
        # wp_delete_attachment nothing to unlink and no way back for it.
        if [[ $move_ok -eq 1 ]]; then
          if wp_run post delete "$id" --force </dev/null >/dev/null 2>&1; then
            n_att_done=$((n_att_done + 1))
          else
            warn "  wp post delete $id failed, the row is still there"
            rc=1
          fi
        else
          warn "  not every file for attachment $id moved, leaving the row in place"
          rc=1
        fi
      done < "$WORK/doomed-attachments.tsv"
      # The count of lines in doomed-attachments.tsv is what was ELIGIBLE, not
      # what happened: a run whose log overstates what it did (every delete
      # skipped because move_ok was 0, say) is worse than a quiet one.
      log "  quarantined $n_att_done attachments"
    fi
  fi

  # --- orphan files: a move, nothing else. WordPress does not know them.
  # The count is of moves that HAPPENED, not of lines in doomed-orphans.txt:
  # that file says what was eligible, and a log that says "quarantined 4000
  # orphan files" over four thousand failed moves is worse than no log at all.
  # The attachments loop above already learned this; the lesson stops being
  # learned in one place if the two loops three lines apart disagree.
  if [[ -s "$WORK/doomed-orphans.txt" ]]; then
    n_orph_done=0
    while IFS= read -r f; do
      if qmove "$f" orphan -; then
        n_orph_done=$((n_orph_done + 1))
      else
        rc=1
      fi
    done < "$WORK/doomed-orphans.txt"
    log "  quarantined $n_orph_done orphan files"
  fi

  # --- stale thumbnails: move, then drop the size from the metadata. Leaving
  # the entry in place would keep WordPress emitting the URL in srcset and turn
  # every removed thumbnail into a 404.
  if [[ -s "$WORK/doomed-thumbs.txt" ]]; then
    : > "$WORK/thumb-sizes.tsv"
    n_thumb_done=0
    while IFS= read -r f; do
      fname="${f##*/}"
      # sizemap.tsv carries no directory in its filename column, so a
      # same-named size from two different attachments (two months' uploads
      # both producing photo-150x150.jpg, say) is only disambiguated by also
      # matching the attachment's own subdirectory, sizemap's 4th column,
      # against this thumbnail's actual directory on disk.
      rel_dir "${f#"$UPLOADS_DIR"/}" >/dev/null; thumb_dir="$RELDIR"
      id=$(awk -F'\t' -v n="$fname" -v d="$thumb_dir" '$3 == n && $4 == d { print $1; exit }' "$WORK/sizemap.tsv")
      sname=$(awk -F'\t' -v n="$fname" -v d="$thumb_dir" '$3 == n && $4 == d { print $2; exit }' "$WORK/sizemap.tsv")
      if ! qmove "$f" thumb "${id:--}"; then
        rc=1
        continue
      fi
      n_thumb_done=$((n_thumb_done + 1))
      [[ -n "$id" && -n "$sname" ]] && printf '%s\t%s\n' "$id" "$sname" >> "$WORK/thumb-sizes.tsv"
    done < "$WORK/doomed-thumbs.txt"
    # Again the count of what happened, not of what was eligible.
    log "  quarantined $n_thumb_done stale thumbnails"

    if [[ -s "$WORK/thumb-sizes.tsv" ]]; then
      # Capture the pre-edit metadata row too: unset() below only removes a
      # size name from the array, it does not tell us the file/width/height
      # that size once had, so without this dump the metadata edit is the one
      # mutation in the whole program that would not round-trip. By the time
      # this eval runs the thumbnail files are already off the site, so this
      # is not a step alongside a reversible move, it is the step that makes
      # the move irreversible: gate it on the dump the same way Critical 3
      # gates the attachment removal, on an actual INSERT INTO rather than
      # -s, since a dump can die right after its header and still be non-empty.
      thumb_ids=$(cut -f1 "$WORK/thumb-sizes.tsv" | sort -u | paste -sd, -)
      wp_run db export - --tables="${PREFIX}postmeta" \
        --where="post_id IN ($thumb_ids) AND meta_key='_wp_attachment_metadata'" \
        --no-create-info --skip-add-drop-table > "$QDIR/rows/thumb-postmeta.sql"

      # One dump covers every affected ID at once, so a single surviving
      # INSERT used to admit the unset() for ALL of them: a dump truncated
      # partway left every later attachment with its metadata unset and no
      # captured row to put back. Each ID is checked against the dump on its
      # own, and only the corroborated ones are handed to the eval. mysqldump
      # writes the row as (meta_id,post_id,'meta_key','meta_value'), so the ID
      # is corroborated when ",<id>,'_wp_attachment_metadata'" appears in the
      # dump. A quoting style this does not recognise reads as "not
      # corroborated", which refuses the edit and leaves a reversible 404 -
      # the safe direction.
      : > "$WORK/thumb-sizes-ok.tsv"
      local tid uncorroborated=0
      while IFS= read -r tid; do
        [[ -n "$tid" ]] || continue
        if grep -qF ",$tid,'_wp_attachment_metadata'" "$QDIR/rows/thumb-postmeta.sql" 2>/dev/null \
           || grep -qF ",$tid,\"_wp_attachment_metadata\"" "$QDIR/rows/thumb-postmeta.sql" 2>/dev/null; then
          awk -F'\t' -v i="$tid" '$1 == i' "$WORK/thumb-sizes.tsv" >> "$WORK/thumb-sizes-ok.tsv"
        else
          uncorroborated=$((uncorroborated + 1))
          warn "  the metadata dump does not corroborate attachment $tid: leaving its metadata untouched, its removed sizes will 404 in srcset but stay restorable"
          rc=1
        fi
      done < <(cut -f1 "$WORK/thumb-sizes.tsv" | sort -u)

      # rows/thumb-sizes.tsv is the record of the sizes actually unset, and it
      # is what the eval reads: $WORK is a root-owned 0700 mktemp directory,
      # unreadable by the site owner wp_run sudos to.
      cp "$WORK/thumb-sizes-ok.tsv" "$QDIR/rows/thumb-sizes.tsv"

      if [[ -s "$WORK/thumb-sizes-ok.tsv" ]]; then
        wp_run eval "
          \$rows = array_filter( explode( \"\n\", file_get_contents( '$QDIR/rows/thumb-sizes.tsv' ) ) );
          \$by_id = array();
          foreach ( \$rows as \$r ) {
            list( \$id, \$size ) = explode( \"\t\", \$r );
            \$by_id[ (int) \$id ][] = \$size;
          }
          foreach ( \$by_id as \$id => \$sizes ) {
            \$m = wp_get_attachment_metadata( \$id );
            if ( ! is_array( \$m ) || empty( \$m['sizes'] ) ) { continue; }
            foreach ( \$sizes as \$s ) { unset( \$m['sizes'][ \$s ] ); }
            wp_update_attachment_metadata( \$id, \$m );
          }
        " >/dev/null 2>&1 || {
          warn "  cannot clean the thumbnail metadata, srcset may 404"
          rc=1
        }
      elif [[ $uncorroborated -eq 0 ]]; then
        warn "  cannot dump the pre-edit attachment metadata, leaving it untouched: stale srcset entries will 404 but stay reversible"
        rc=1
      fi
    fi
  fi

  if [[ ! -s "$QDIR/manifest.tsv" ]]; then
    # manifest.tsv itself was created empty at the top of this function, so
    # it is always present here and would block a plain rmdir "$QDIR" on its
    # own; it is provably empty in this branch (that's the branch condition),
    # so removing it first is always safe. Everything else stays a plain
    # rmdir, never rm -rf: it refuses on a non-empty directory, so if a row
    # dump is sitting in rows/ (every qmove for a doomed attachment failed,
    # say, with the dumps already on disk) the teardown simply does not
    # happen, instead of taking the only copy of those rows down with it.
    rm -f "$QDIR/manifest.tsv"
    # qmove creates the files/wp-content/uploads/... skeleton with mkdir -p
    # before it moves anything, so a run in which every move failed leaves an
    # empty tree standing and the rmdir below correctly refuses to remove a
    # non-empty directory. The husk that survives is then the newest entry
    # under the site's quarantine directory, and the next successful run's
    # prune_quarantine counts it towards KEEP_QUARANTINE and deletes the
    # oldest REAL set to make room: a failed run silently costs a recovery
    # point. -empty only ever removes directories that contain nothing, so it
    # cannot touch a tree that still holds a quarantined file.
    find "$QDIR/files" -type d -empty -delete 2>/dev/null
    rmdir "$QDIR/files" "$QDIR/rows" "$QDIR" 2>/dev/null
    if [[ $rc -ne 0 ]]; then
      # "Nothing to quarantine" and "nothing made it into quarantine" look
      # identical from here - an empty manifest - and only one of them is good
      # news. With $QUARANTINE_ROOT unwritable this is the branch the whole
      # run ends in, and it used to end in it with an ok and exit 0.
      warn "  nothing was quarantined: every operation failed (see the warnings above)"
      return "$rc"
    fi
    log "  nothing to quarantine"
    return 0
  fi

  cp "$LOG_FILE" "$QDIR/report.txt" 2>/dev/null
  ok "quarantine: $QDIR ($(wc -l < "$QDIR/manifest.tsv") items)"
  # The whole safety story of this tool is that the move is reversible, and
  # the one moment the operator is looking at the output is right now.
  log "  restore it with: wp-media-clean.sh --restore $STAMP --site $SITE_NAME"
  prune_quarantine
  if [[ $rc -ne 0 ]]; then
    warn "  the quarantine pass finished with failures: it did not do everything it was asked to, see the warnings above"
  fi
  return "$rc"
}

# --------------------------------------------------------------- restore

list_quarantine_site() {
  local site_dir="$QUARANTINE_ROOT/$SITE_SLUG" d n
  [[ -d "$site_dir" ]] || { log "  no quarantine set"; return 0; }
  for d in "$site_dir"/*/; do
    [[ -d "$d" ]] || continue
    # `n=$(wc -l < "$d/manifest.tsv" 2>/dev/null || echo 0)` looks like it
    # covers a manifest-less set, but it does not: the `<` redirection is
    # opened before wc even runs, so a missing file fails the redirection
    # itself and prints a raw "No such file or directory" to stderr right
    # there -- the 2>/dev/null on the command line is too late to catch it.
    # Guard on -s first instead of relying on the redirection to fail softly.
    if [[ -s "$d/manifest.tsv" ]]; then
      n=$(wc -l < "$d/manifest.tsv")
    else
      n=0
    fi
    log "  $(basename "$d")  $n items  $(du -sh "$d" 2>/dev/null | cut -f1)"
  done
}

# restore_chown_path <rel>
# Chowns $SITE_PATH/$rel to $SITE_OWNER:$SITE_GROUP, then walks EVERY ancestor
# up to (but not including) $UPLOADS_DIR, chowning each one whose ownership is
# wrong.
#
# The walk deliberately does not stop at the first correctly-owned ancestor.
# It used to, on the theory that everything above a correct directory must
# already be correct too, and that is false the moment a chown fails: run 1
# fixes uploads/2024/05 but fails on uploads/2024 and reports the failure
# ("re-running is safe and will retry it"); run 2 reaches the now-correct
# uploads/2024/05, breaks there, never revisits the still-root-owned
# uploads/2024, and reports "ok ... remove it by hand" over a directory the
# web server still cannot write. An uploads path is two or three levels deep,
# so walking it out costs two extra stat calls -- against a false "ok" on the
# one code path an operator reaches only after this tool has already damaged
# their site.
#
# The stop condition is containment, not string equality: the walk continues
# only while $path is strictly inside $UPLOADS_DIR. Equality alone silently
# overshoots when basedir carries a trailing slash (reachable through the
# legacy upload_path option) -- the compare never matches, and the walk runs
# past uploads into wp-content, stopping only where the ownership happens to
# match. Both sides are stripped of trailing slashes before the compare.
#
# This is the ONLY place restore_site chowns anything. Two earlier rounds
# each added a second call site instead: one that skipped the leaf file
# entirely on a "nothing to move" shortcut, and its fix in turn skipped the
# ancestor directories whenever the entry that would have created them was
# the one whose move failed. Both drifted from the "real" chown in a
# different way because there were two of them. A single routine, called
# unconditionally for every manifest entry that ends up correctly placed --
# whether the move happened just now, in an earlier run, or turns out to
# have needed no move at all because the file was already there -- cannot
# drift, because there is only one of it, and it decides what to chown from
# current ownership on disk rather than from bookkeeping about what this
# particular call created.
#
# Sets $chown_failed and adds to $failures on any failure; both are
# restore_site's locals, reachable here because this is a direct call, not a
# subshell -- bash's normal dynamic scoping applies.
restore_chown_path() {
  local rel="$1" path owner stop prefix
  path="$SITE_PATH/$rel"
  chown "$SITE_OWNER":"$SITE_GROUP" "$path" 2>>"$LOG_FILE" \
    || { warn "  cannot chown $rel to $SITE_OWNER:$SITE_GROUP"; chown_failed=1; failures=$((failures + 1)); }

  # "${v##*[!/]}" is the trailing run of slashes, so "${v%"${v##*[!/]}"}" is
  # $v with them removed. dirname never produces a trailing slash, so only
  # $UPLOADS_DIR really needs it, but normalising the leaf too keeps the two
  # sides of the comparison built the same way.
  stop="${UPLOADS_DIR%"${UPLOADS_DIR##*[!/]}"}"
  # An empty or root $UPLOADS_DIR gives the walk no floor at all, and a walk
  # with no floor chowns every directory between the file and /. load_site
  # rejects an uploads directory that is not a real directory, so this cannot
  # happen in production; if it somehow does, chown the file and stop.
  [[ -n "$stop" && "$stop" != "/" ]] || return 0
  prefix="$stop/"

  path="${path%"${path##*[!/]}"}"
  path="$(dirname "$path")"
  # Strictly inside $UPLOADS_DIR: "$prefix"* matches ancestors below it and
  # nothing at or above it, so a rel that somehow does not live under uploads
  # chowns its own file and no directory at all, rather than walking up into
  # wp-content.
  while [[ "$path" == "$prefix"* ]]; do
    owner=$(stat -c '%U:%G' "$path" 2>/dev/null)
    if [[ "$owner" != "$SITE_OWNER:$SITE_GROUP" ]]; then
      chown "$SITE_OWNER":"$SITE_GROUP" "$path" 2>>"$LOG_FILE" \
        || { warn "  cannot chown $path to $SITE_OWNER:$SITE_GROUP"; chown_failed=1; failures=$((failures + 1)); }
    fi
    path="$(dirname "$path")"
  done
}

restore_site() {
  local qdir="$QUARANTINE_ROOT/$SITE_SLUG/$RESTORE_STAMP"
  [[ -d "$qdir" ]] || { warn "  no quarantine set $RESTORE_STAMP for this site"; return 1; }

  # failures counts real problems anywhere in the run (a file that would not
  # move, a malformed manifest line, a chown that did not take, a row import
  # that failed). It is what decides whether this function is allowed to say
  # "ok" and tell the operator the quarantine set is now disposable -- a bare
  # warn() on its own changes nothing about the return value, so without this
  # counter every one of those problems could still end in a false "restored"
  # report. malformed_failed/move_failed/chown_failed/import_failed record
  # which *kind* of problem occurred, each set only where that exact kind of
  # attempt was actually made, so the closing message can tell the operator
  # something more useful than "investigate": a chown or import failure is
  # always safe to fix by re-running, a malformed manifest line never is
  # (no amount of re-running invents a path that was never recorded), and a
  # move failure means investigate the quarantined file itself.
  local class rel att conflicts=0 failures=0
  local malformed_failed=0 move_failed=0 chown_failed=0 import_failed=0

  # A missing or empty manifest is not an error: quarantine_site's own
  # teardown removes an empty manifest.tsv while leaving a populated rows/
  # behind it (every file move failed but the row dumps already landed), so
  # that combination is reachable and legitimate. It just means there is
  # nothing to move back; the row import below still runs.
  if [[ -s "$qdir/manifest.tsv" ]]; then
    # Refuse rather than overwrite -- but only for a GENUINE conflict: the
    # destination exists AND the quarantined copy is still sitting in
    # files/. A destination that exists with no quarantined copy left behind
    # is not a conflict, it is an entry an earlier run (or an earlier pass
    # of this same run) already restored; per-entry, this is what lets a
    # partially-restored set finish on a second attempt instead of aborting
    # on conflicts that were never real, which is the whole reason a
    # dedicated "already restored" shortcut used to exist here. Removing
    # that shortcut and checking each entry directly costs nothing (the same
    # data, $qdir/files/$rel, was already available) and cannot drift the
    # way the shortcut itself did, twice, across the last two rounds.
    #
    # `read` returns non-zero on a final line with no trailing newline, and a
    # plain `while read ...; do ... done < file` treats that as end of input
    # and never runs the loop body for it at all -- not even far enough to
    # reach the "$rel is empty" guard below. The `|| [[ -n "$class$rel$att" ]]`
    # keeps a non-empty last line in the loop exactly once, so a truncated
    # manifest still gets a chance to be flagged as malformed instead of
    # silently vanishing before that check even runs. This same idiom
    # repeats on the second manifest.tsv read below.
    while IFS=$'\t' read -r class rel att || [[ -n "$class$rel$att" ]]; do
      [[ -n "$rel" ]] || { warn "  malformed manifest line (missing path), skipping"; malformed_failed=1; failures=$((failures + 1)); continue; }
      if [[ -e "$SITE_PATH/$rel" && -e "$qdir/files/$rel" ]]; then
        warn "  conflict, already present: $rel"
        conflicts=$((conflicts + 1))
      fi
    done < "$qdir/manifest.tsv"
    [[ $conflicts -eq 0 ]] || { warn "  $conflicts conflicts, restore aborted"; return 1; }

    local destdir
    while IFS=$'\t' read -r class rel att || [[ -n "$class$rel$att" ]]; do
      [[ -n "$rel" ]] || { warn "  malformed manifest line (missing path), skipping"; malformed_failed=1; failures=$((failures + 1)); continue; }

      # Already restored (an earlier run, or an earlier pass of this one):
      # the destination is there and nothing is left in files/ to move.
      # Tested here rather than left to fall out of a failing `mv`: the
      # post-move filesystem check below does classify this case correctly,
      # but only after mv has written "cannot stat ...: No such file or
      # directory" into the operator's log -- once per entry, on a run that
      # is otherwise wholly successful, in the one log an operator reads
      # while deciding whether their recovery worked.
      if [[ -e "$SITE_PATH/$rel" && ! -e "$qdir/files/$rel" ]]; then
        restore_chown_path "$rel"
        continue
      fi

      destdir="$(dirname "$SITE_PATH/$rel")"
      mkdir -p "$destdir"

      # mv -n exits 0 even when it silently skips an existing destination
      # (GNU coreutils) -- the same trap qmove guards against, twenty lines
      # earlier in this file, when moving files INTO quarantine. A
      # destination created between the conflict scan above and this move
      # (a concurrent upload on a live site) is exactly the race that scan
      # cannot close, and the skip it causes here is invisible to an exit
      # status check. Only the filesystem afterwards can tell a real move
      # from a no-clobber skip: the move only counts if the destination now
      # exists and the quarantine copy is gone. Keep this check exactly as it
      # is -- the already-restored short-circuit above narrows what reaches
      # it, but every move actually attempted here still needs it, because
      # `mv -n` reports success for the skip it is about to catch.
      mv -n "$qdir/files/$rel" "$SITE_PATH/$rel" 2>>"$LOG_FILE"
      if [[ -e "$SITE_PATH/$rel" && ! -e "$qdir/files/$rel" ]]; then
        restore_chown_path "$rel"
      else
        warn "  cannot restore $rel"
        move_failed=1
        failures=$((failures + 1))
      fi
    done < "$qdir/manifest.tsv"
  else
    log "  no manifest (or it is empty): nothing to move back, importing rows only"
  fi

  # Files first, then rows: a real failure between the two still leaves files
  # present and rows absent, and that is recoverable by re-running the
  # restore -- every entry that already made it across is recognised as such
  # per-entry above, so a second run reaches the row import instead of
  # refusing on conflicts that are not conflicts.
  #
  # thumb-postmeta.sql carries the pre-edit _wp_attachment_metadata for
  # attachments whose stale thumbnails were removed; posts.sql/postmeta.sql
  # carry every row of a restored attachment, _wp_attachment_metadata
  # included. Importing all three restores the metadata exactly as it was, so
  # there is nothing left for `wp media regenerate` to do afterwards -
  # running it here would rewrite metadata down to only the currently
  # registered sizes and undo the very entries this import just restored.
  local f
  for f in "$qdir"/rows/posts.sql "$qdir"/rows/postmeta.sql "$qdir"/rows/thumb-postmeta.sql; do
    [[ -s "$f" ]] || continue
    log "  importing $(basename "$f")"
    wp_run db import "$f" >/dev/null || { warn "  cannot import $(basename "$f")"; import_failed=1; failures=$((failures + 1)); }
  done

  if [[ $failures -eq 0 ]]; then
    ok "restored $qdir into $SITE_PATH"
    log "  the quarantine set is left in place: remove it by hand once you are satisfied"
    return 0
  fi

  local advice=""
  if [[ $malformed_failed -eq 1 ]]; then
    advice+="the manifest has malformed entries with no recorded path -- those cannot be restored automatically and re-running will not fix them; inspect $qdir/manifest.tsv by hand. "
  fi
  if [[ $move_failed -eq 1 ]]; then
    advice+="some files could not be moved back, likely because the quarantined copy under $qdir/files is missing or unreadable -- investigate before re-running; a re-run will safely retry only the entries that failed. "
  fi
  if [[ $chown_failed -eq 1 ]]; then
    advice+="ownership could not be set on some restored files -- re-running is safe and will retry it. "
  fi
  if [[ $import_failed -eq 1 ]]; then
    advice+="the database rows could not be imported -- re-running is safe and will retry the import. "
  fi
  [[ -n "$advice" ]] || advice="investigate before re-running. "
  warn "  restore of $qdir finished with $failures failure(s): ${advice}the quarantine set is left in place."
  return 1
}

main() {
  parse_args "$@"
  [[ $EUID -eq 0 ]] || die "root required (use sudo)"
  require_cmds
  mkdir -p "$LOG_DIR" "$QUARANTINE_ROOT"
  LOG_FILE="$LOG_DIR/$STAMP.log"

  case "$ACTION" in
    list-quarantine)
      log "=== quarantine sets ==="
      local site_rc=0
      for_each_site list_quarantine_site || site_rc=$?
      [[ ${#FAILED[@]} -eq 0 ]] || warn "sites with problems: ${FAILED[*]}"
      [[ ${#FAILED[@]} -eq 0 && $site_rc -eq 0 ]]
      ;;
    restore)
      log "=== restore $RESTORE_STAMP ==="
      local site_rc=0
      for_each_site restore_site || site_rc=$?
      [[ ${#FAILED[@]} -eq 0 ]] || warn "sites with problems: ${FAILED[*]}"
      [[ ${#FAILED[@]} -eq 0 && $site_rc -eq 0 ]]
      ;;
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
