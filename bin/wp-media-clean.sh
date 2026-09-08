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
collect_size_map() {
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
  : > "$WORK/doomed-attachments.tsv"
  : > "$WORK/doomed-orphans.txt"
  : > "$WORK/doomed-thumbs.txt"
  : > "$WORK/doomed-attachment-files.txt"

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
    else
      local id pdate parent rel base
      while IFS=$'\t' read -r id pdate parent rel; do
        [[ -n "$id" ]] || continue
        [[ "$pdate" < "$cutoff" ]] || continue
        [[ $KEEP_ATTACHED -eq 0 || "$parent" == "0" ]] || continue
        base=$(basename "$rel")
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
      dir=$(dirname "$rel")
      # dirname prints "." for a root-level upload (uploads_use_yearmonth_folders
      # off): drop it so the entry has no "./" prefix and matches $relf below
      # exactly. The prefix is passed to awk as a variable rather than spliced
      # into a sed replacement, so a directory name containing "|" or "&" is
      # applied literally instead of being read as sed syntax.
      [[ "$dir" == "." ]] && dir=""
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

  # filename -> size name, for the thumbnails the metadata knows about. A
  # single file can be shared by two registered sizes with identical
  # dimensions, so this can hold several rows for the same filename.
  awk -F'\t' '{ print $3 "\t" $2 }' "$WORK/sizemap.tsv" | sort -u > "$WORK/file-to-size.tsv"

  local f relf fname canon sizenames tbase text
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

  while IFS= read -r f; do
    fname=$(basename "$f")

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
    grep -qxF "$relf" "$WORK/doomed-attachment-files.txt" && continue

    if grep -qxF "$fname" "$WORK/known-files.txt"; then
      # Known to WordPress. Only a thumbnail stored under a size name that is
      # no longer registered can go -- and only when every size name mapped
      # to this filename is dead, since two live sizes with identical
      # dimensions collapse onto the same file.
      [[ $thumbs_ok -eq 1 ]] || continue
      [[ "$ONLY_CLASS" == "all" || "$ONLY_CLASS" == "thumbs" ]] || continue
      parse_thumb_size "$fname" >/dev/null || continue
      sizenames=$(awk -F'\t' -v n="$fname" '$1 == n { print $2 }' "$WORK/file-to-size.tsv" | sort -u)
      [[ -n "$sizenames" ]] || continue
      printf '%s\n' "$sizenames" | grep -qxFf - "$WORK/live-sizes.txt" && continue
      printf '%s\n' "$f" >> "$WORK/doomed-thumbs.txt"
      continue
    fi

    # Unknown to WordPress. A -scaled / -rotated / -e<timestamp> variant of a
    # known upload is not an orphan.
    canon=$(canonical_original "$fname")
    if [[ "$canon" != "$fname" ]] && grep -qxF "$canon" "$WORK/known-files.txt"; then
      continue
    fi

    # A generated size of a live attachment that the metadata has forgotten:
    # a leftover from an earlier regeneration.
    if IFS='|' read -r tbase _ text < <(parse_thumb_size "$fname"); then
      if grep -qxF "$tbase.$text" "$WORK/known-files.txt"; then
        [[ $thumbs_ok -eq 1 ]] || continue
        [[ "$ONLY_CLASS" == "all" || "$ONLY_CLASS" == "thumbs" ]] || continue
        printf '%s\n' "$f" >> "$WORK/doomed-thumbs.txt"
        continue
      fi
    fi

    [[ "$ONLY_CLASS" == "all" || "$ONLY_CLASS" == "orphans" ]] || continue
    printf '%s\n' "$f" >> "$WORK/doomed-orphans.txt"
  done < <("${find_cmd[@]}" 2>/dev/null)
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
    dir=$(dirname "$rel")
    # Same root-level case as classify()'s doomed-attachment-files.txt: drop
    # the "." dirname gives for an upload with no directory component, so
    # the two agree on which files exist under a doomed attachment.
    [[ "$dir" == "." ]] && dir=""
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
    cut -f2 "$WORK/doomed-attachments.tsv" | head -5 | sed 's/^/    /'
    head -5 "$WORK/doomed-orphans.txt" | sed 's/^/    /'
    printf '  %sfull list in %s%s\n' "$c_dim" "$LOG_FILE" "$c_off"
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
  collect_haystack
  collect_id_set

  if [[ ! -s "$WORK/inventory.tsv" ]]; then
    log "  no attachment found, nothing to do"
    return 0
  fi
  if [[ ! -s "$WORK/haystack.txt" ]]; then
    warn "  refusing to classify with an empty haystack"
    return 1
  fi

  classify
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

quarantine_site() {
  QDIR="$QUARANTINE_ROOT/$SITE_SLUG/$STAMP"
  mkdir -p "$QDIR/files" "$QDIR/rows"
  : > "$QDIR/manifest.tsv"

  local ids id rel dir fname f sname move_ok n_att_done
  local has_rows_posts has_rows_postmeta footer_posts footer_postmeta dump_ok
  local thumb_ids thumb_dir

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
    else
      grep -q '^INSERT INTO' "$QDIR/rows/posts.sql"    && has_rows_posts=1    || has_rows_posts=0
      grep -q '^INSERT INTO' "$QDIR/rows/postmeta.sql" && has_rows_postmeta=1 || has_rows_postmeta=0
      grep -q -- '-- Dump completed' "$QDIR/rows/posts.sql"    && footer_posts=1    || footer_posts=0
      grep -q -- '-- Dump completed' "$QDIR/rows/postmeta.sql" && footer_postmeta=1 || footer_postmeta=0

      if [[ $has_rows_posts -eq 0 || $has_rows_postmeta -eq 0 ]]; then
        warn "  the row dump captured no rows: attachments left untouched"
      elif [[ $footer_posts -ne $footer_postmeta ]]; then
        warn "  one row dump looks truncated (completion footer in one but not the other): attachments left untouched"
      else
        [[ $footer_posts -eq 0 ]] && warn "  wp db export does not emit a completion footer here, proceeding on the INSERT check alone"
        dump_ok=1
      fi
    fi

    if [[ $dump_ok -eq 1 ]]; then
      n_att_done=0
      while IFS=$'\t' read -r id rel; do
        dir=$(dirname "$rel")
        move_ok=1
        qmove "$UPLOADS_DIR/$rel" attachment "$id" || move_ok=0
        # every generated size of this attachment
        while IFS= read -r fname; do
          if [[ -f "$UPLOADS_DIR/$dir/$fname" ]]; then
            qmove "$UPLOADS_DIR/$dir/$fname" attachment "$id" || move_ok=0
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
          fi
        else
          warn "  not every file for attachment $id moved, leaving the row in place"
        fi
      done < "$WORK/doomed-attachments.tsv"
      # The count of lines in doomed-attachments.tsv is what was ELIGIBLE, not
      # what happened: a run whose log overstates what it did (every delete
      # skipped because move_ok was 0, say) is worse than a quiet one.
      log "  quarantined $n_att_done attachments"
    fi
  fi

  # --- orphan files: a move, nothing else. WordPress does not know them.
  if [[ -s "$WORK/doomed-orphans.txt" ]]; then
    while IFS= read -r f; do qmove "$f" orphan -; done < "$WORK/doomed-orphans.txt"
    log "  quarantined $(wc -l < "$WORK/doomed-orphans.txt") orphan files"
  fi

  # --- stale thumbnails: move, then drop the size from the metadata. Leaving
  # the entry in place would keep WordPress emitting the URL in srcset and turn
  # every removed thumbnail into a 404.
  if [[ -s "$WORK/doomed-thumbs.txt" ]]; then
    : > "$WORK/thumb-sizes.tsv"
    while IFS= read -r f; do
      fname=$(basename "$f")
      # sizemap.tsv carries no directory in its filename column, so a
      # same-named size from two different attachments (two months' uploads
      # both producing photo-150x150.jpg, say) is only disambiguated by also
      # matching the attachment's own subdirectory, sizemap's 4th column,
      # against this thumbnail's actual directory on disk.
      thumb_dir=$(dirname "${f#"$UPLOADS_DIR"/}")
      [[ "$thumb_dir" == "." ]] && thumb_dir=""
      id=$(awk -F'\t' -v n="$fname" -v d="$thumb_dir" '$3 == n && $4 == d { print $1; exit }' "$WORK/sizemap.tsv")
      sname=$(awk -F'\t' -v n="$fname" -v d="$thumb_dir" '$3 == n && $4 == d { print $2; exit }' "$WORK/sizemap.tsv")
      qmove "$f" thumb "${id:--}" || continue
      [[ -n "$id" && -n "$sname" ]] && printf '%s\t%s\n' "$id" "$sname" >> "$WORK/thumb-sizes.tsv"
    done < "$WORK/doomed-thumbs.txt"
    log "  quarantined $(wc -l < "$WORK/doomed-thumbs.txt") stale thumbnails"

    if [[ -s "$WORK/thumb-sizes.tsv" ]]; then
      cp "$WORK/thumb-sizes.tsv" "$QDIR/rows/thumb-sizes.tsv"

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

      if grep -q '^INSERT INTO' "$QDIR/rows/thumb-postmeta.sql" 2>/dev/null; then
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
        " >/dev/null 2>&1 || warn "  cannot clean the thumbnail metadata, srcset may 404"
      else
        warn "  cannot dump the pre-edit attachment metadata, leaving it untouched: stale srcset entries will 404 but stay reversible"
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
    rmdir "$QDIR/files" "$QDIR/rows" "$QDIR" 2>/dev/null
    log "  nothing to quarantine"
    return 0
  fi

  cp "$LOG_FILE" "$QDIR/report.txt" 2>/dev/null
  ok "quarantine: $QDIR ($(wc -l < "$QDIR/manifest.tsv") items)"
  prune_quarantine
  return 0
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

restore_site() {
  local qdir="$QUARANTINE_ROOT/$SITE_SLUG/$RESTORE_STAMP"
  [[ -d "$qdir" ]] || { warn "  no quarantine set $RESTORE_STAMP for this site"; return 1; }

  # failures counts real problems in either phase (a file that would not
  # move, a chown that did not take, a row import that failed). It is what
  # decides whether this function is allowed to say "ok" and tell the
  # operator the quarantine set is now disposable -- a bare warn() on its own
  # changes nothing about the return value, so without this counter every one
  # of those problems could still end in a false "restored" report.
  local class rel att conflicts=0 failures=0

  # A missing or empty manifest is not an error: quarantine_site's own
  # teardown removes an empty manifest.tsv while leaving a populated rows/
  # behind it (every file move failed but the row dumps already landed), so
  # that combination is reachable and legitimate. It just means there is
  # nothing to move back; the row import below still runs.
  if [[ -s "$qdir/manifest.tsv" ]]; then
    # A restore run a second time, after a first run already moved every
    # file back, is not a conflict: if every destination in the manifest is
    # already in place AND quarantine's files/ holds nothing left to move,
    # that is the unambiguous signature of "the file phase already
    # happened" (this same restore run again, or an earlier attempt that got
    # the files across but failed before the row import). Recognise that
    # case and go straight to the row import instead of reporting every line
    # as a conflict and refusing outright -- otherwise a restore that fails
    # only on the database step can never be completed by re-running it,
    # which is exactly the recovery path this function exists to offer.
    local all_present=1
    while IFS=$'\t' read -r class rel att; do
      [[ -n "$rel" ]] || continue
      [[ -e "$SITE_PATH/$rel" ]] || { all_present=0; break; }
    done < "$qdir/manifest.tsv"

    local files_left
    files_left=$(find "$qdir/files" -type f -print -quit 2>/dev/null)

    if [[ $all_present -eq 1 && -z "$files_left" ]]; then
      log "  every file is already at its destination and quarantine/files is empty: already restored, importing the rows only"
    else
      # Refuse rather than overwrite: a destination that already exists means
      # something was re-uploaded since, and clobbering it would be a second
      # data loss on top of whatever made the restore necessary. Check every
      # conflict before moving anything, so a partial restore never happens.
      while IFS=$'\t' read -r class rel att; do
        [[ -n "$rel" ]] || continue
        [[ -e "$SITE_PATH/$rel" ]] && { warn "  conflict, already present: $rel"; conflicts=$((conflicts + 1)); }
      done < "$qdir/manifest.tsv"
      [[ $conflicts -eq 0 ]] || { warn "  $conflicts conflicts, restore aborted"; return 1; }

      local destdir dir_existed
      while IFS=$'\t' read -r class rel att; do
        [[ -n "$rel" ]] || continue
        destdir="$(dirname "$SITE_PATH/$rel")"
        dir_existed=1
        [[ -d "$destdir" ]] || dir_existed=0
        mkdir -p "$destdir"

        # mv -n exits 0 even when it silently skips an existing destination
        # (GNU coreutils) -- the same trap qmove guards against, twenty lines
        # earlier in this file, when moving files INTO quarantine. A
        # destination created between the conflict scan above and this move
        # (a concurrent upload on a live site) is exactly the race that scan
        # cannot close, and the skip it causes here is invisible to an exit
        # status check. Only the filesystem afterwards can tell a real move
        # from a no-clobber skip: the move only actually happened if the
        # destination now exists and the quarantine copy is gone.
        mv -n "$qdir/files/$rel" "$SITE_PATH/$rel" 2>>"$LOG_FILE"
        if [[ -e "$SITE_PATH/$rel" && ! -e "$qdir/files/$rel" ]]; then
          # Chown exactly what this restore touched, from the manifest's own
          # path, rather than a guessed "$SITE_PATH/wp-content/uploads": a
          # custom WP_CONTENT_DIR/UPLOADS constant or a legacy upload_path
          # makes that guess wrong, chown fails on it, and 2>/dev/null used
          # to swallow that silently, leaving the restored files root-owned.
          # When mkdir -p above had to create the destination directory, it
          # is new and holds only what this loop puts in it, so recursing
          # into it is still exactly-scoped.
          if [[ $dir_existed -eq 0 ]]; then
            chown -R "$SITE_OWNER":"$SITE_GROUP" "$destdir" 2>>"$LOG_FILE" \
              || { warn "  cannot chown $destdir to $SITE_OWNER:$SITE_GROUP"; failures=$((failures + 1)); }
          else
            chown "$SITE_OWNER":"$SITE_GROUP" "$SITE_PATH/$rel" 2>>"$LOG_FILE" \
              || { warn "  cannot chown $rel to $SITE_OWNER:$SITE_GROUP"; failures=$((failures + 1)); }
          fi
        else
          warn "  cannot restore $rel"
          failures=$((failures + 1))
        fi
      done < "$qdir/manifest.tsv"
    fi
  else
    log "  no manifest (or it is empty): nothing to move back, importing rows only"
  fi

  # Files first, then rows: a real failure between the two still leaves files
  # present and rows absent, and that is recoverable by re-running the
  # restore -- the "already restored" check above is exactly what makes the
  # second run reach the row import instead of refusing on the conflicts it
  # would otherwise see for every file now sitting at its destination.
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
    wp_run db import "$f" >/dev/null || { warn "  cannot import $(basename "$f")"; failures=$((failures + 1)); }
  done

  if [[ $failures -eq 0 ]]; then
    ok "restored $qdir into $SITE_PATH"
    log "  the quarantine set is left in place: remove it by hand once you are satisfied"
    return 0
  fi

  warn "  restore of $qdir finished with $failures failure(s): NOT fully restored, keeping the quarantine set -- investigate and re-run the restore"
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
