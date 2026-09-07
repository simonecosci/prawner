# wp-media-clean.sh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `wp-media-clean.sh` command to `prawner` that reclaims disk space by moving unused media — orphan attachments, orphan files and stale thumbnails — into a reversible quarantine.

**Architecture:** One self-contained bash script in `bin/`, matching the shape of `wp-site.sh` and `wp-update.sh`: run as root, discover sites by finding `wp-config.php` under `/var/www`, drive each site through `wp-cli` as the user owning the installation. Detection is set arithmetic over three sets built once per site (a text haystack, an ID set, an inventory), intersected with a single `grep -oF -f` pass. Removal is a move into `/var/backups/wp-media/` plus a `mysqldump` of the affected rows.

**Tech Stack:** bash 4+, GNU coreutils, GNU grep, wp-cli, MySQL/MariaDB. No new dependencies. A short inline `wp eval` reads the serialized `_wp_attachment_metadata`; there is no separate PHP file.

**Spec:** `docs/superpowers/specs/2026-09-08-media-cleanup-design.md`

## Global Constraints

- Dry-run is the default. Nothing moves without an explicit `--apply`.
- Removal is a move into quarantine, never a delete. The only real deletion is retention pruning.
- Every heuristic errs towards a false "in use", never a false "orphan".
- Single script, installed by copying one file. No sourced libraries.
- `set -uo pipefail` at the top, as in the sibling scripts. Not `-e`: the loops must survive one failing site.
- The script must be safely `source`-able so `tests/run.sh` can call its pure functions. All top-level side effects — the root check, `mkdir`, argument parsing — live inside `main`.
- Never compare generated thumbnail dimensions against registered size dimensions. Compare size *names*. See the spec.
- Style follows `wp-site.sh`: `c_red`/`c_grn`/`c_yel`/`c_dim`/`c_off` colours, `die`/`warn`/`ok`/`info` helpers, `${VAR:-default}` environment overrides at the top.
- Comments and documentation in English, matching commit `d28fb50`.

---

### Task 1: Script skeleton, argument parsing and test runner

**Files:**
- Create: `bin/wp-media-clean.sh`
- Create: `tests/run.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: the global configuration variables (`WWW_ROOT`, `QUARANTINE_ROOT`, `LOG_DIR`, `KEEP_QUARANTINE`, `MIN_AGE_DAYS`, `WP_CLI_CACHE_ROOT`), the parsed option variables (`ONLY_SITE`, `APPLY`, `ONLY_CLASS`, `MIN_AGE_DAYS`, `KEEP_ATTACHED`, `SCAN_FILES`, `ACTION`, `RESTORE_STAMP`), the log helpers `die`/`warn`/`ok`/`info`/`log`, and `main`. Every later task adds functions to this same file and calls them from `main`.

- [ ] **Step 1: Write the failing test**

Create `tests/run.sh`. It sources the script under test and asserts. The sourcing must not execute anything.

```bash
#!/usr/bin/env bash
#
# tests/run.sh - dependency-free tests for the pure functions of
#                bin/wp-media-clean.sh
#
# These cover the string and set logic only: no WordPress, no database, no
# filesystem under /var/www. Run with: ./tests/run.sh
#
set -uo pipefail

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Sourcing must be side effect free: if the script runs main() on source, this
# line hangs or exits and every test below is skipped.
# shellcheck source=../bin/wp-media-clean.sh
source "$TESTS_DIR/../bin/wp-media-clean.sh"

PASS=0
FAIL=0
t_red=$'\033[31m'; t_grn=$'\033[32m'; t_off=$'\033[0m'

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
    printf '%s  ok  %s%s\n' "$t_grn" "$desc" "$t_off"
  else
    FAIL=$((FAIL + 1))
    printf '%sFAIL  %s%s\n' "$t_red" "$desc" "$t_off"
    printf '      expected: %q\n' "$expected"
    printf '      actual:   %q\n' "$actual"
  fi
}

assert_fails() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    FAIL=$((FAIL + 1))
    printf '%sFAIL  %s (expected a non-zero exit)%s\n' "$t_red" "$desc" "$t_off"
  else
    PASS=$((PASS + 1))
    printf '%s  ok  %s%s\n' "$t_grn" "$desc" "$t_off"
  fi
}

# ---------------------------------------------------------------- skeleton

assert_eq "sourcing does not run main" "1" "$(type -t main >/dev/null && echo 1)"
assert_eq "defaults: dry run" "0" "$APPLY"
assert_eq "defaults: min age" "30" "$MIN_AGE_DAYS"

# ---------------------------------------------------------------- summary

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.sh`
Expected: FAIL — `bin/wp-media-clean.sh: No such file or directory`.

- [ ] **Step 3: Write minimal implementation**

Create `bin/wp-media-clean.sh`:

```bash
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

usage() {
  sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `chmod +x bin/wp-media-clean.sh tests/run.sh && bash tests/run.sh`
Expected: PASS — `3 passed, 0 failed`.

Also check the help path by hand: `bash bin/wp-media-clean.sh --help` prints the header and the option list and exits 0, and `bash bin/wp-media-clean.sh --only nonsense` exits with the `--only takes one of` error.

- [ ] **Step 5: Commit**

```bash
git add bin/wp-media-clean.sh tests/run.sh
git commit -m "Add wp-media-clean.sh skeleton and test runner"
```

---

### Task 2: Filename helpers

**Files:**
- Modify: `bin/wp-media-clean.sh` (add functions after the `log` helper, before `usage`)
- Test: `tests/run.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `parse_thumb_size <filename>` — prints `<base>|<WxH>|<ext>` on stdout and returns 0 when the name is a generated size variant; returns 1 otherwise.
  - `canonical_original <filename>` — prints the filename with a `-scaled`, `-rotated` or `-e<timestamp>` suffix stripped, or the name unchanged.
  - `urlencode_name <filename>` — prints the percent-encoded form.

- [ ] **Step 1: Write the failing test**

Insert into `tests/run.sh`, immediately before the `# ---- summary` block:

```bash
# ---------------------------------------------------------------- filenames

assert_eq "thumb: plain"        "photo|800x600|jpg"      "$(parse_thumb_size 'photo-800x600.jpg')"
assert_eq "thumb: dashed base"  "my-holiday|1024x768|png" "$(parse_thumb_size 'my-holiday-1024x768.png')"
assert_eq "thumb: uppercase ext" "photo|150x150|JPEG"    "$(parse_thumb_size 'photo-150x150.JPEG')"
assert_fails "thumb: original is not a thumb"   parse_thumb_size 'photo.jpg'
assert_fails "thumb: numeric suffix is not one" parse_thumb_size 'photo-2.jpg'
assert_fails "thumb: size in the middle"        parse_thumb_size 'photo-800x600-detail.jpg'
assert_fails "thumb: no base before the size"   parse_thumb_size '1024x768.jpg'

assert_eq "variant: scaled"    "photo.jpg"        "$(canonical_original 'photo-scaled.jpg')"
assert_eq "variant: rotated"   "photo.png"        "$(canonical_original 'photo-rotated.png')"
assert_eq "variant: edited"    "photo.jpg"        "$(canonical_original 'photo-e1699999999.jpg')"
assert_eq "variant: plain"     "photo.jpg"        "$(canonical_original 'photo.jpg')"
assert_eq "variant: short -eN is not an edit" "phone-e5.jpg" "$(canonical_original 'phone-e5.jpg')"

assert_eq "encode: space"      "my%20photo.jpg"   "$(urlencode_name 'my photo.jpg')"
assert_eq "encode: safe chars" "foto_1-2.jpg"     "$(urlencode_name 'foto_1-2.jpg')"
assert_eq "encode: utf8"       "citt%C3%A0.jpg"   "$(urlencode_name 'città.jpg')"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.sh`
Expected: FAIL — `parse_thumb_size: command not found` on the first new assertion.

- [ ] **Step 3: Write minimal implementation**

Add to `bin/wp-media-clean.sh`:

```bash
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run.sh`
Expected: PASS — `18 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add bin/wp-media-clean.sh tests/run.sh
git commit -m "Add filename helpers for thumbnails, upload variants and URL encoding"
```

---

### Task 3: Reference token helpers

**Files:**
- Modify: `bin/wp-media-clean.sh` (add after `urlencode_name`)
- Test: `tests/run.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `extract_id_tokens` — filter, reads arbitrary text on stdin and prints, one per line, the integers that appear in a shape identifying an attachment reference.
  - `expand_id_list` — filter, reads lines that are a bare integer or a comma separated list of integers and prints each integer on its own line.
  - `name_is_used <filename>` — returns 0 when the filename, or its percent-encoded form, is present in `$WORK/used-names.txt`.

- [ ] **Step 1: Write the failing test**

Insert into `tests/run.sh` before the summary block:

```bash
# ---------------------------------------------------------------- tokens

assert_eq "id: wp-image class" "42" \
  "$(printf '<img class="x wp-image-42" src="/u/p.jpg">' | extract_id_tokens)"
assert_eq "id: block attribute" "99" \
  "$(printf '<!-- wp:image {"id":99,"sizeSlug":"large"} -->' | extract_id_tokens)"
assert_eq "id: escaped block attribute" "77" \
  "$(printf '&quot;id&quot;:77' | extract_id_tokens)"
assert_eq "id: serialized array" "0
45
1
78" "$(printf 'a:2:{i:0;i:45;i:1;i:78;}' | extract_id_tokens)"
assert_eq "id: serialized numeric string" "123" \
  "$(printf 's:3:"123"' | extract_id_tokens)"
# A bare number in prose must not become an ID: that is what would make the
# ID set swallow the whole library and report nothing.
assert_eq "id: bare number in prose is ignored" "" \
  "$(printf 'published in 2024 with 15 photos' | extract_id_tokens)"

assert_eq "list: comma separated" "12
45
78" "$(printf '12,45,78\n' | expand_id_list)"
assert_eq "list: single value" "123" "$(printf '123\n' | expand_id_list)"
assert_eq "list: non numeric ignored" "" "$(printf 'abc\n1.5\n\n' | expand_id_list)"

# name_is_used reads $WORK/used-names.txt, so the test provides one.
WORK=$(mktemp -d)
printf 'photo.jpg\nmy%%20holiday.jpg\n' > "$WORK/used-names.txt"
assert_eq "used: plain hit"    "yes" "$(name_is_used 'photo.jpg' && echo yes)"
assert_eq "used: miss"         ""    "$(name_is_used 'other.jpg' && echo yes)"
# The reference in the content is percent-encoded while the upload on disk is
# not: without checking the encoded form too, this file looks unused.
assert_eq "used: encoded hit"  "yes" "$(name_is_used 'my holiday.jpg' && echo yes)"
rm -rf "$WORK"; unset WORK
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.sh`
Expected: FAIL — `extract_id_tokens: command not found`.

- [ ] **Step 3: Write minimal implementation**

Add to `bin/wp-media-clean.sh`:

```bash
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run.sh`
Expected: PASS — `30 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add bin/wp-media-clean.sh tests/run.sh
git commit -m "Add reference token extraction and set difference helpers"
```

---

### Task 4: Site discovery, wp-cli plumbing and assumption check

**Files:**
- Modify: `bin/wp-media-clean.sh`

**Interfaces:**
- Consumes: the config globals and `die`/`warn`/`log` from Task 1.
- Produces:
  - `require_cmds` — exits when a needed binary is missing.
  - `wp_run <args...>` — runs wp-cli against `$SITE_PATH` as `$SITE_OWNER`.
  - `discover_sites` — populates the array `CONFIGS` with the `wp-config.php` paths, honouring `--site`.
  - `load_site <config_path>` — sets `SITE_PATH`, `SITE_NAME`, `SITE_SLUG`, `SITE_OWNER`, `SITE_GROUP`, `SITE_CACHE_DIR`, `PREFIX`, `UPLOADS_DIR`. Returns 1 when the installation cannot be loaded.
  - `for_each_site <function_name>` — the loop later tasks hang their work on; calls the named function once per site with the site globals set, tallies `OK`/`FAILED`.

- [ ] **Step 1: Verify the wp-cli assumptions the spec flagged**

Before writing code, confirm on a machine that has a real site. These decide whether the implementation below works as written.

```bash
cd /var/www/<a-site>/wordpress
sudo -u <owner> wp db query "SELECT 1" --skip-column-names
sudo -u <owner> wp media image-size --format=csv | head
sudo -u <owner> wp db export - --tables=wp_options --where="option_name='siteurl'" --no-create-info | head -20
sudo -u <owner> wp eval '$u = wp_get_upload_dir(); echo $u["basedir"];'
```

Expected: the first prints `1` with no header row; the second prints a CSV whose first column is `name`; the third prints `INSERT INTO` statements and no `CREATE TABLE`; the fourth prints an absolute path.

If `wp db export` rejects `--where`, fall back to `mysqldump` invoked directly with the credentials from `wp-config.php` and record the change in the spec's assumptions section. Do not proceed to Task 7 with an unverified dump mechanism.

- [ ] **Step 2: Write the implementation**

Add to `bin/wp-media-clean.sh`, before `usage`:

```bash
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
  local fn="$1" cfg
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
    log ""
    log "--- ${SITE_PATH#"$WWW_ROOT"/}"
    if load_site "$cfg" && "$fn"; then
      OK+=("$SITE_NAME")
    else
      FAILED+=("${SITE_PATH#"$WWW_ROOT"/}")
    fi
  done
}
```

Replace the body of `main` with:

```bash
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
      for_each_site clean_site
      log ""
      log "=== done: ${#OK[@]} ok, ${#FAILED[@]} failed ==="
      [[ ${#FAILED[@]} -eq 0 ]] || warn "sites with problems: ${FAILED[*]}"
      [[ ${#FAILED[@]} -eq 0 ]]
      ;;
  esac
}
```

Add a temporary `clean_site` so the loop is runnable, to be replaced in Task 6:

```bash
clean_site() {
  log "  prefix=$PREFIX uploads=$UPLOADS_DIR owner=$SITE_OWNER:$SITE_GROUP"
  return 0
}
```

- [ ] **Step 3: Verify**

Run: `bash tests/run.sh` — expected: still `30 passed, 0 failed` (sourcing must not break).

On the VPS, run `sudo bash bin/wp-media-clean.sh` and check that it lists every site with a plausible prefix and uploads directory, and `sudo bash bin/wp-media-clean.sh --site <one-domain>` narrows to that one. Then confirm a bogus filter is not silently a no-op success: `sudo bash bin/wp-media-clean.sh --site does-not-exist` reports zero sites.

- [ ] **Step 4: Commit**

```bash
git add bin/wp-media-clean.sh
git commit -m "Add site discovery and wp-cli plumbing to wp-media-clean.sh"
```

---

### Task 5: Data collection

**Files:**
- Modify: `bin/wp-media-clean.sh`

**Interfaces:**
- Consumes: `wp_run`, `PREFIX`, `UPLOADS_DIR`, `SITE_PATH` (Task 4); `extract_id_tokens`, `expand_id_list`, `urlencode_name` (Tasks 2-3).
- Produces, all writing into the per-site scratch directory `$WORK`:
  - `collect_inventory` → `$WORK/inventory.tsv`, columns `ID`, `post_date`, `post_parent`, `relative_path`.
  - `collect_size_map` → `$WORK/sizemap.tsv`, columns `ID`, `size_name`, `filename`; the `original_image` value appears under the pseudo name `__original`.
  - `collect_registered_sizes` → `$WORK/registered.txt`, one size name per line.
  - `collect_haystack` → `$WORK/haystack.txt`.
  - `collect_id_set` → `$WORK/ids.txt`, sorted unique.

- [ ] **Step 1: Write the implementation**

Add to `bin/wp-media-clean.sh`:

```bash
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
      grep -rIoh -f "$WORK/names.txt" "$SITE_PATH/wp-content/$d" 2>/dev/null >> "$out"
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
```

Note the ordering constraint this creates: `collect_names` needs the inventory and the size map, and `collect_haystack` needs `names.txt` for its filesystem grep. Task 6 sequences them.

- [ ] **Step 2: Verify**

Run: `bash tests/run.sh` — expected: `30 passed, 0 failed`.

On the VPS, temporarily point `clean_site` at the collectors to inspect the output:

```bash
clean_site() {
  WORK=$(mktemp -d); trap 'rm -rf "$WORK"' RETURN
  collect_inventory; collect_size_map; collect_registered_sizes
  collect_names; collect_haystack; collect_id_set
  log "  inventory=$(wc -l < "$WORK/inventory.tsv") sizemap=$(wc -l < "$WORK/sizemap.tsv") names=$(wc -l < "$WORK/names.txt") ids=$(wc -l < "$WORK/ids.txt") haystack=$(wc -c < "$WORK/haystack.txt")B"
}
```

Expected: the inventory count matches the media library count in wp-admin, the size map is several times larger, the registered size list contains `thumbnail`, `medium` and `large`, and the ID set is non-empty on any site that uses featured images. An empty haystack or an empty inventory is a bug, not a clean site — stop and investigate.

- [ ] **Step 3: Commit**

```bash
git add bin/wp-media-clean.sh
git commit -m "Collect the inventory, size map, haystack and ID set per site"
```

---

### Task 6: Classification and the dry-run report

**Files:**
- Modify: `bin/wp-media-clean.sh` (replace the temporary `clean_site`)

**Interfaces:**
- Consumes: everything from Task 5, plus `parse_thumb_size`, `canonical_original`, `name_is_used`.
- Produces:
  - `classify` → writes `$WORK/doomed-attachments.tsv` (`ID`, `relative_path`), `$WORK/doomed-orphans.txt` and `$WORK/doomed-thumbs.txt` (absolute paths).
  - `report` — prints the per-class counts and reclaimable bytes and writes the full list to the log.
  - `clean_site` — the real one: sequences collection, classification, reporting and, when `--apply` is set, the removal added in Task 7.

- [ ] **Step 1: Write the implementation**

Replace `clean_site` and add:

```bash
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

  local cutoff
  cutoff=$(date -d "-${MIN_AGE_DAYS} days" '+%Y-%m-%d %H:%M:%S')

  # --- attachments
  if [[ "$ONLY_CLASS" == "all" || "$ONLY_CLASS" == "attachments" ]]; then
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

  # --- files on disk
  # Everything that legitimately belongs to an attachment, as bare filenames.
  # sed rather than `xargs basename`: uploads with spaces in the name are
  # common and xargs would split them into pieces.
  sed 's|.*/||' < <(cut -f4 "$WORK/inventory.tsv") | sort -u > "$WORK/known-files.txt"
  cut -f3 "$WORK/sizemap.tsv"   | sort -u >> "$WORK/known-files.txt"
  sort -u -o "$WORK/known-files.txt" "$WORK/known-files.txt"

  # Size names still registered, plus the pseudo name for the untouched
  # original of a -scaled upload, which is never a stale thumbnail.
  cp "$WORK/registered.txt" "$WORK/live-sizes.txt"
  printf '__original\n' >> "$WORK/live-sizes.txt"

  # filename -> size name, for the thumbnails the metadata knows about.
  awk -F'\t' '{ print $3 "\t" $2 }' "$WORK/sizemap.tsv" | sort -u > "$WORK/file-to-size.tsv"

  local f fname canon sizename tbase text
  while IFS= read -r f; do
    fname=$(basename "$f")

    # Referenced by name anywhere? Then it stays, whatever it is. This is what
    # protects srcset candidates for sizes that are no longer registered.
    name_is_used "$fname" && continue

    if grep -qxF "$fname" "$WORK/known-files.txt"; then
      # Known to WordPress. Only a thumbnail stored under a size name that is
      # no longer registered can go.
      [[ "$ONLY_CLASS" == "all" || "$ONLY_CLASS" == "thumbs" ]] || continue
      parse_thumb_size "$fname" >/dev/null || continue
      sizename=$(awk -F'\t' -v n="$fname" '$1 == n { print $2; exit }' "$WORK/file-to-size.tsv")
      [[ -n "$sizename" ]] || continue
      grep -qxF "$sizename" "$WORK/live-sizes.txt" && continue
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
        [[ "$ONLY_CLASS" == "all" || "$ONLY_CLASS" == "thumbs" ]] || continue
        printf '%s\n' "$f" >> "$WORK/doomed-thumbs.txt"
        continue
      fi
    fi

    [[ "$ONLY_CLASS" == "all" || "$ONLY_CLASS" == "orphans" ]] || continue
    printf '%s\n' "$f" >> "$WORK/doomed-orphans.txt"
  done < <(find "$UPLOADS_DIR" -type f 2>/dev/null)
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
    awk -F'\t' -v i="$id" '$1 == i { print $3 }' "$WORK/sizemap.tsv" \
      | sed "s|^|$UPLOADS_DIR/$dir/|" >> "$WORK/att-files.txt"
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
```

Add a temporary stub so the file stays runnable until Task 7:

```bash
quarantine_site() { warn "  --apply not implemented yet"; return 0; }
```

- [ ] **Step 2: Verify**

Run: `bash tests/run.sh` — expected: `30 passed, 0 failed`.

On the VPS, `sudo bash bin/wp-media-clean.sh --site <domain>` and read the report critically. This is the step where a design error shows up, so check by hand:

- pick one file from `--- stale thumbs` in the log and confirm with `grep -c "$(basename FILE)"` against the site's `post_content` that nothing references it;
- confirm the site's logo, favicon and a WooCommerce product gallery image are **not** in `--- attachments`;
- confirm a `-scaled.jpg` upload and its untouched original are in neither list;
- confirm an image used only in a draft is in neither list.

If any of those appears, stop and fix the classification before going near `--apply`.

- [ ] **Step 3: Commit**

```bash
git add bin/wp-media-clean.sh
git commit -m "Classify unused media and report reclaimable space"
```

---

### Task 7: Quarantine

**Files:**
- Modify: `bin/wp-media-clean.sh` (replace the `quarantine_site` stub)

**Interfaces:**
- Consumes: the `$WORK/doomed-*` files, `$UPLOADS_DIR`, `$SITE_PATH`, `$SITE_SLUG`, `wp_run`.
- Produces:
  - `quarantine_site` — performs the whole removal for one site.
  - `qmove <absolute_path> <class> <attachment_id_or_dash>` — moves one file under `$QDIR/files/` preserving its path relative to `$SITE_PATH`, and appends to `manifest.tsv`.
  - `prune_quarantine` — keeps the newest `$KEEP_QUARANTINE` sets for the site.

- [ ] **Step 1: Write the implementation**

```bash
# ------------------------------------------------------------ quarantine

# Moves one file into the quarantine, keeping its path relative to the docroot
# so that --restore is a plain move back.
qmove() {
  local src="$1" class="$2" att="$3" rel dest
  rel="${src#"$SITE_PATH"/}"
  dest="$QDIR/files/$rel"
  mkdir -p "$(dirname "$dest")"
  if mv -n "$src" "$dest" 2>>"$LOG_FILE"; then
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
    log "  pruning old quarantine set: $old"
    rm -rf "$old"
  done
}

quarantine_site() {
  QDIR="$QUARANTINE_ROOT/$SITE_SLUG/$STAMP"
  mkdir -p "$QDIR/files" "$QDIR/rows"
  : > "$QDIR/manifest.tsv"

  local ids id rel dir fname f sname

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
    # can still exit 0 and leave a truncated file. Non-empty is what matters,
    # and without both dumps the removal must not happen at all.
    if [[ ! -s "$QDIR/rows/posts.sql" || ! -s "$QDIR/rows/postmeta.sql" ]]; then
      warn "  the row dump failed or is empty: attachments left untouched"
    else
      while IFS=$'\t' read -r id rel; do
        dir=$(dirname "$rel")
        qmove "$UPLOADS_DIR/$rel" attachment "$id"
        # every generated size of this attachment
        awk -F'\t' -v i="$id" '$1 == i { print $3 }' "$WORK/sizemap.tsv" \
          | while IFS= read -r fname; do
              [[ -f "$UPLOADS_DIR/$dir/$fname" ]] && qmove "$UPLOADS_DIR/$dir/$fname" attachment "$id"
            done
        wp_run post delete "$id" --force >/dev/null 2>&1 \
          || warn "  wp post delete $id failed, the row is still there"
      done < "$WORK/doomed-attachments.tsv"
      log "  quarantined $(wc -l < "$WORK/doomed-attachments.tsv") attachments"
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
      id=$(awk -F'\t' -v n="$fname" '$3 == n { print $1; exit }' "$WORK/sizemap.tsv")
      sname=$(awk -F'\t' -v n="$fname" '$3 == n { print $2; exit }' "$WORK/sizemap.tsv")
      qmove "$f" thumb "${id:--}" || continue
      [[ -n "$id" && -n "$sname" ]] && printf '%s\t%s\n' "$id" "$sname" >> "$WORK/thumb-sizes.tsv"
    done < "$WORK/doomed-thumbs.txt"
    log "  quarantined $(wc -l < "$WORK/doomed-thumbs.txt") stale thumbnails"

    if [[ -s "$WORK/thumb-sizes.tsv" ]]; then
      cp "$WORK/thumb-sizes.tsv" "$QDIR/rows/thumb-sizes.tsv"
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
    fi
  fi

  if [[ ! -s "$QDIR/manifest.tsv" ]]; then
    rmdir -p "$QDIR/files" "$QDIR/rows" 2>/dev/null
    rm -rf "$QDIR"
    log "  nothing to quarantine"
    return 0
  fi

  cp "$LOG_FILE" "$QDIR/report.txt" 2>/dev/null
  ok "quarantine: $QDIR ($(wc -l < "$QDIR/manifest.tsv") items)"
  prune_quarantine
  return 0
}
```

- [ ] **Step 2: Verify**

Run: `bash tests/run.sh` — expected: `30 passed, 0 failed`.

Then, on a **test site only**, never a production one on the first run:

```bash
sudo bash bin/wp-media-clean.sh --site <test-domain>           # read the report
sudo bash bin/wp-media-clean.sh --site <test-domain> --apply
```

Check that `/var/backups/wp-media/<slug>/<stamp>/` contains `files/`, `manifest.tsv` and non-empty `rows/posts.sql` and `rows/postmeta.sql`; that the removed attachments no longer appear in wp-admin; and that the home page and one post using images still render correctly.

Then verify the retention: run `--apply` four times and confirm only three sets survive under the site's quarantine directory.

- [ ] **Step 3: Commit**

```bash
git add bin/wp-media-clean.sh
git commit -m "Move unused media into a reversible quarantine"
```

---

### Task 8: Listing and restoring a quarantine set

**Files:**
- Modify: `bin/wp-media-clean.sh` (replace the two `die "not implemented yet"` branches in `main`)

**Interfaces:**
- Consumes: `for_each_site`, `load_site`, `wp_run`, `QUARANTINE_ROOT`, `SITE_SLUG`, `SITE_PATH`, `RESTORE_STAMP`.
- Produces: `list_quarantine_site` and `restore_site`, both usable as the `for_each_site` callback.

- [ ] **Step 1: Write the implementation**

```bash
# --------------------------------------------------------------- restore

list_quarantine_site() {
  local site_dir="$QUARANTINE_ROOT/$SITE_SLUG" d n
  [[ -d "$site_dir" ]] || { log "  no quarantine set"; return 0; }
  for d in "$site_dir"/*/; do
    [[ -d "$d" ]] || continue
    n=$(wc -l < "$d/manifest.tsv" 2>/dev/null || echo 0)
    log "  $(basename "$d")  $n items  $(du -sh "$d" 2>/dev/null | cut -f1)"
  done
}

restore_site() {
  local qdir="$QUARANTINE_ROOT/$SITE_SLUG/$RESTORE_STAMP"
  [[ -d "$qdir" ]] || { warn "  no quarantine set $RESTORE_STAMP for this site"; return 1; }
  [[ -f "$qdir/manifest.tsv" ]] || { warn "  $qdir has no manifest"; return 1; }

  # Refuse rather than overwrite: a destination that already exists means
  # something was re-uploaded since, and clobbering it would be a second bug on
  # top of whatever made the restore necessary.
  local class rel att conflicts=0
  while IFS=$'\t' read -r class rel att; do
    [[ -e "$SITE_PATH/$rel" ]] && { warn "  conflict, already present: $rel"; conflicts=$((conflicts + 1)); }
  done < "$qdir/manifest.tsv"
  [[ $conflicts -eq 0 ]] || { warn "  $conflicts conflicts, restore aborted"; return 1; }

  while IFS=$'\t' read -r class rel att; do
    mkdir -p "$(dirname "$SITE_PATH/$rel")"
    mv -n "$qdir/files/$rel" "$SITE_PATH/$rel" || warn "  cannot restore $rel"
  done < "$qdir/manifest.tsv"

  chown -R "$SITE_OWNER":"$SITE_GROUP" "$SITE_PATH/wp-content/uploads" 2>/dev/null

  local f
  for f in "$qdir"/rows/posts.sql "$qdir"/rows/postmeta.sql; do
    [[ -s "$f" ]] || continue
    log "  importing $(basename "$f")"
    wp_run db import "$f" >/dev/null || warn "  cannot import $(basename "$f")"
  done

  # Rebuild the metadata of the attachments whose thumbnails came back.
  local ids
  ids=$(awk -F'\t' '$3 != "-" { print $3 }' "$qdir/manifest.tsv" | sort -u | paste -sd, -)
  if [[ -n "$ids" ]]; then
    wp_run media regenerate --only-missing --yes "$ids" >/dev/null 2>&1 \
      || warn "  cannot regenerate the metadata, run wp media regenerate by hand"
  fi

  ok "restored $qdir into $SITE_PATH"
  log "  the quarantine set is left in place: remove it by hand once you are satisfied"
  return 0
}
```

And in `main`, replace the two stubs:

```bash
    list-quarantine)
      log "=== quarantine sets ==="
      for_each_site list_quarantine_site
      ;;
    restore)
      log "=== restore $RESTORE_STAMP ==="
      for_each_site restore_site
      [[ ${#FAILED[@]} -eq 0 ]]
      ;;
```

`list_quarantine_site` needs `SITE_SLUG` but not a working database, whereas `for_each_site` calls `load_site`, which gives up when wp-cli cannot reach the site. That is the right trade for `restore`, which needs the database, but it would hide quarantine sets belonging to a broken site. Accept it and say so in the help text: listing requires the site to be loadable.

- [ ] **Step 2: Verify**

On the test site, after a `--apply` run:

```bash
sudo bash bin/wp-media-clean.sh --list-quarantine --site <test-domain>
sudo bash bin/wp-media-clean.sh --restore <stamp> --site <test-domain>
```

Expected: the listing shows the set with its item count and size; the restore puts every file back, reimports the rows, and the previously removed attachments are visible again in wp-admin with working thumbnails. Run the restore a second time and confirm it aborts on conflicts instead of overwriting.

- [ ] **Step 3: Commit**

```bash
git add bin/wp-media-clean.sh
git commit -m "Add quarantine listing and restore to wp-media-clean.sh"
```

---

### Task 9: Installation and documentation

**Files:**
- Modify: `install.sh:29` (the `for name in` loop) and `install.sh:56-57` (the usage summary)
- Modify: `uninstall.sh:32` (the `for name in` loop)
- Modify: `README.md`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: the finished `bin/wp-media-clean.sh`.
- Produces: nothing other tasks depend on.

- [ ] **Step 1: Update the installers**

In `install.sh` and `uninstall.sh`, change both loops from:

```bash
for name in wp-site.sh wp-update.sh; do
```

to:

```bash
for name in wp-site.sh wp-update.sh wp-media-clean.sh; do
```

In `install.sh`, add to the usage summary printed at the end, after the `wp-update.sh` line:

```bash
echo "       wp-media-clean.sh [--site <domain>] [--apply] [--only <class>]"
```

No cron entry: this command is manual by design.

- [ ] **Step 2: Update the README**

Add a section after the `wp-update.sh` description in the intro list:

```markdown
- **`wp-media-clean.sh`** — reclaims disk space by moving unused media into a
  reversible quarantine: attachments nothing references any more, files under
  `uploads/` that belong to no attachment, and thumbnails for image sizes the
  theme no longer registers.
```

And a usage section after the `wp-update.sh` one:

````markdown
## wp-media-clean.sh — media cleanup

Reports, by default. It only moves something when `--apply` is given, and even
then nothing is deleted: files go to `/var/backups/wp-media/<site>/<stamp>/`
together with a dump of the affected database rows, and `--restore` puts them
back. Real deletion happens only when a set falls out of the `KEEP_QUARANTINE`
retention window (three sets per site).

```bash
wp-media-clean.sh                                   # report every site
wp-media-clean.sh --site example.com                # report one site
wp-media-clean.sh --site example.com --apply        # move to quarantine
wp-media-clean.sh --only thumbs --apply             # one class only
wp-media-clean.sh --list-quarantine --site example.com
wp-media-clean.sh --restore 20260908-143000 --site example.com
```

An image counts as used when its filename appears anywhere in the database —
post content, custom fields, options, term and user meta, including drafts,
revisions, scheduled posts and the trash — or in the theme and plugin files, or
when its attachment ID appears as a reference (featured image, ACF field,
WooCommerce gallery). Both tests err towards keeping the file.

Attachments uploaded in the last 30 days are skipped, so that images not yet
inserted anywhere survive. Change it with `--min-age`.

Read the report before running `--apply` the first time on a site. Images
referenced only from outside WordPress — a CDN manifest, another site
hotlinking — are invisible to the tool, which is why removal is a quarantine
and not a delete.
````

Add `wp-media-clean.sh` to the conventions table with the row `Media quarantine | /var/backups/wp-media/<site>-<timestamp>/`, matching the existing formatting.

- [ ] **Step 3: Update the CHANGELOG**

Add an entry at the top following the file's existing format, describing the new command in one or two lines.

- [ ] **Step 4: Verify**

```bash
bash -n install.sh && bash -n uninstall.sh && bash -n bin/wp-media-clean.sh
bash tests/run.sh
sudo ./install.sh --prefix /tmp/prawner-test && ls -l /tmp/prawner-test
```

Expected: the syntax checks pass, the tests pass, and all three scripts appear in `/tmp/prawner-test`. Clean up with `rm -rf /tmp/prawner-test`.

- [ ] **Step 5: Commit**

```bash
git add install.sh uninstall.sh README.md CHANGELOG.md
git commit -m "Install and document wp-media-clean.sh"
```

---

## Notes for the executor

**shellcheck.** If available, run `shellcheck bin/wp-media-clean.sh` at the end of each task. `SC2016` fires on the single-quoted PHP passed to `wp eval` and is expected — that string must not be expanded by bash. `SC2064` on the `trap` in `clean_site` is deliberate and already annotated.

**The riskiest task is 6, not 7.** Task 7 only moves what Task 6 decided. A classification bug quarantines live images across every site at once, and the restore is per site and per set. Do the manual checks in Task 6 properly before touching `--apply`.

**Performance.** `collect_size_map` calls `wp_get_attachment_metadata` once per attachment, so a library of tens of thousands of items takes minutes. That is acceptable for a manual command run occasionally. If it proves too slow, batch the eval rather than moving the parsing into bash.
