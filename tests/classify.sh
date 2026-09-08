#!/usr/bin/env bash
#
# tests/classify.sh - dependency-free tests for the classification path of
#                     bin/wp-media-clean.sh
#
# classify() decides what gets moved. Until this file existed it had zero
# assertions on it while restore_site had a hundred - and the review that
# followed found, by driving classify() over a fixture by hand, that an empty
# sizemap.tsv makes every thumbnail on the site "stale". Both halves of the
# program had been read carefully; only one of them had ever been executed.
#
# The governing property is the first one in the spec: every heuristic errs
# towards a false "in use", never a false "orphan". A collector that failed
# must therefore never be read as "the answer is nothing" - which is what the
# guards below are about - and the classification rules themselves must keep
# protecting the files they were written to protect. Both kinds of assertion
# are here.
#
# tests/run.sh covers the pure string functions and touches no filesystem;
# tests/restore.sh covers restore_site; tests/quarantine.sh covers the moves.
# This suite needs a filesystem (find really walks a real tree - a stubbed
# find would only ever prove the stub) but no WordPress: classify() reads the
# collector output files, so every case hands it a $WORK built by hand. The
# collector tests at the end do stub wp_run, since a wp-cli that fails in a
# particular way is precisely what they are about.
#
#   bash tests/classify.sh
#
# WMC_SCRIPT points the suite at a different copy of the script - that is how
# these assertions were checked to actually discriminate: each was run against
# a copy with the relevant fix removed and seen to fail there.
#
set -uo pipefail

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
WMC_SCRIPT="${WMC_SCRIPT:-$TESTS_DIR/../bin/wp-media-clean.sh}"

# shellcheck source=../bin/wp-media-clean.sh
source "$WMC_SCRIPT"

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

assert_contains() {
  local desc="$1" needle="$2" hay="$3"
  if [[ "$hay" == *"$needle"* ]]; then
    PASS=$((PASS + 1))
    printf '%s  ok  %s%s\n' "$t_grn" "$desc" "$t_off"
  else
    FAIL=$((FAIL + 1))
    printf '%sFAIL  %s%s\n' "$t_red" "$desc" "$t_off"
    printf '      expected to contain: %q\n' "$needle"
    printf '      in: %q\n' "$hay"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" hay="$3"
  if [[ "$hay" != *"$needle"* ]]; then
    PASS=$((PASS + 1))
    printf '%s  ok  %s%s\n' "$t_grn" "$desc" "$t_off"
  else
    FAIL=$((FAIL + 1))
    printf '%sFAIL  %s%s\n' "$t_red" "$desc" "$t_off"
    printf '      expected NOT to contain: %q\n' "$needle"
    printf '      in: %q\n' "$hay"
  fi
}

section() { printf '\n--- %s\n' "$*"; }

# ------------------------------------------------------------------ harness

SANDBOX="$(mktemp -d)"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

CASE_N=0

# An attachment old enough to be eligible, and one that is not. MIN_AGE_DAYS
# defaults to 30, and the cutoff is computed from `date` at classify() time.
OLD_DATE="2020-01-01 08:00:00"
NEW_DATE="$(date '+%Y-%m-%d %H:%M:%S')"

# new_case <label>
# Most of what it assigns is read by the sourced script, not by this file, so
# the static check below cannot see the use.
# shellcheck disable=SC2034
# A fresh $WORK with every collector output present but empty, a fresh uploads
# tree, and every global classify() reads set to its default. Production sets
# these in load_site() and the collectors; nothing here calls either, because
# they need wp-cli and a live database.
new_case() {
  CASE_N=$((CASE_N + 1))
  section "$1"
  CASE_DIR="$SANDBOX/case$CASE_N"
  WORK="$CASE_DIR/work"
  SITE_PATH="$CASE_DIR/site"
  UPLOADS_DIR="$SITE_PATH/wp-content/uploads"
  LOG_FILE="$CASE_DIR/run.log"
  WP_LOG="$CASE_DIR/wp.log"
  FIND_LOG="$CASE_DIR/find.log"
  ONLY_CLASS="all"
  MIN_AGE_DAYS=30
  KEEP_ATTACHED=0
  SCAN_FILES=0
  APPLY=0
  PREFIX="wp_"
  SIZEMAP_COMPLETE=1
  IDS_OK=1
  EXCLUDE_UPLOAD_DIRS="woocommerce_uploads wpforms backups wp-personal-data-exports elementor cache"
  WP_FAIL_MATCH=""
  mkdir -p "$WORK" "$UPLOADS_DIR"
  : > "$WORK/inventory.tsv"; : > "$WORK/sizemap.tsv"; : > "$WORK/registered.txt"
  : > "$WORK/haystack.txt"; : > "$WORK/ids.txt"; : > "$WORK/names.txt"
  : > "$LOG_FILE"; : > "$WP_LOG"; : > "$FIND_LOG"
}

# inv <id> <post_date> <post_parent> <rel>    a row of the attachment inventory
inv() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$WORK/inventory.tsv"; }

# size <id> <size name> <filename> <dir>      a row of the size map
size() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$WORK/sizemap.tsv"; }

# registered <name>...                        the still-registered size names
registered() { printf '%s\n' "$@" >> "$WORK/registered.txt"; }

# hay <text>                                  a line of database content
hay() { printf '%s\n' "$1" >> "$WORK/haystack.txt"; }

# att_ids <id>...                             the bare-integer reference set
att_ids() { printf '%s\n' "$@" >> "$WORK/ids.txt"; }

# upload <rel path>                           a real file under uploads/
upload() {
  mkdir -p "$(dirname "$UPLOADS_DIR/$1")"
  printf 'x\n' > "$UPLOADS_DIR/$1"
}

# --------------------------------------------------------------- the stubs

# Real find, wrapped only so a test can ask whether classify() walked the tree
# at all. A stubbed find would prove nothing about the walk itself.
find() {
  printf '%s\n' "$*" >> "$FIND_LOG"
  command find "$@"
}

# Only the collector cases at the end call this; classify() never does.
wp_run() {
  local args="$*"
  printf '%s\n' "$args" >> "$WP_LOG"
  [[ -n "$WP_FAIL_MATCH" && "$args" == *"$WP_FAIL_MATCH"* ]] && return 1
  printf '%s\n' "$WP_OUT"
  return 0
}
WP_OUT=""

# --------------------------------------------------------------- observers

# collect_names is the real thing: names.txt is derived from inventory.tsv and
# sizemap.tsv exactly as it is in production, so a fixture cannot accidentally
# hand classify() a pattern file the collectors would never have produced.
run_classify() {
  collect_names
  OUT="$(classify 2>&1)"
  RC=$?
}

yesno()     { if "$@"; then echo yes; else echo no; fi; }
n_lines()   { if [[ -s "$1" ]]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }
doomed_thumb() { yesno grep -Fxq -- "$UPLOADS_DIR/$1" "$WORK/doomed-thumbs.txt"; }
doomed_orph()  { yesno grep -Fxq -- "$UPLOADS_DIR/$1" "$WORK/doomed-orphans.txt"; }
doomed_att()   { yesno grep -Fq -- "$1" "$WORK/doomed-attachments.tsv"; }
walked()       { yesno test -s "$FIND_LOG"; }

# =============================================== A. Critical 1: the size map

# collect_size_map's wp eval loops get_post_meta() over every attachment on
# the site, so a large library with a low memory_limit or max_execution_time
# gets an empty or truncated dump - and its only response used to be `|| warn`.
# Both known-files.txt and names.txt are built from sizemap.tsv, so an empty
# one means no thumbnail is known AND no thumbnail name is in the haystack
# pattern file. Every "photo-150x150.jpg" then reaches the "generated size the
# metadata has forgotten" branch, where parse_thumb_size reduces it to
# "photo.jpg" - which IS known - and the whole site's thumbnails are stale.
new_case "A: an empty size map must not make every thumbnail on the site stale"
inv 1 "$OLD_DATE" 0 "2024/01/photo.jpg"
registered thumbnail medium large
hay '<img src="/wp-content/uploads/2024/01/photo.jpg">'
att_ids 1
upload "2024/01/photo.jpg"
upload "2024/01/photo-150x150.jpg"
upload "2024/01/photo-300x200.jpg"
# sizemap.tsv is left empty: the collector came back with nothing.
run_classify

assert_eq       "A: nothing is doomed as a stale thumb"   "0" "$(n_lines "$WORK/doomed-thumbs.txt")"
assert_eq       "A: the 150x150 thumbnail survives"       "no" "$(doomed_thumb "2024/01/photo-150x150.jpg")"
assert_eq       "A: the 300x200 thumbnail survives"       "no" "$(doomed_thumb "2024/01/photo-300x200.jpg")"
assert_eq       "A: and it is not called an orphan either" "0" "$(n_lines "$WORK/doomed-orphans.txt")"
assert_contains "A: says the size map is why"             "size map is empty" "$OUT"
assert_contains "A: says the thumbs class was skipped"    "skipping the thumbs class" "$OUT"

# The control: the same tree with the size map the collector should have
# produced classifies nothing either, so case A is not passing because the
# fixture happens to be inert.
new_case "A2: control - the same tree with a correct size map dooms nothing"
inv 1 "$OLD_DATE" 0 "2024/01/photo.jpg"
size 1 thumbnail "photo-150x150.jpg" "2024/01"
size 1 medium    "photo-300x200.jpg" "2024/01"
registered thumbnail medium large
hay '<img src="/wp-content/uploads/2024/01/photo.jpg">'
att_ids 1
upload "2024/01/photo.jpg"
upload "2024/01/photo-150x150.jpg"
upload "2024/01/photo-300x200.jpg"
run_classify

assert_eq       "A2: nothing doomed as a thumb"    "0" "$(n_lines "$WORK/doomed-thumbs.txt")"
assert_eq       "A2: nothing doomed as an orphan"  "0" "$(n_lines "$WORK/doomed-orphans.txt")"
assert_not_contains "A2: and no size-map warning"  "size map is empty" "$OUT"

# A size map that is present but was cut short is worse than an empty one: it
# dooms only the thumbnails of the attachments after the point of death, which
# looks like a perfectly ordinary result.
new_case "A3: a truncated size map skips the thumbs class too"
inv 1 "$OLD_DATE" 0 "2024/01/a.jpg"
inv 2 "$OLD_DATE" 0 "2024/01/b.jpg"
size 1 thumbnail "a-150x150.jpg" "2024/01"
# attachment 2's rows never made it out of PHP.
registered thumbnail
att_ids 1 2
upload "2024/01/a.jpg"; upload "2024/01/a-150x150.jpg"
upload "2024/01/b.jpg"; upload "2024/01/b-150x150.jpg"
SIZEMAP_COMPLETE=0
run_classify

assert_eq       "A3: b's thumbnail is not doomed"      "no" "$(doomed_thumb "2024/01/b-150x150.jpg")"
assert_eq       "A3: nothing at all is doomed"         "0"  "$(n_lines "$WORK/doomed-thumbs.txt")"
assert_contains "A3: says the size map is incomplete"  "size map is incomplete" "$OUT"

# The guards above skip the THUMBS class - and that is not enough, because the
# size map is not one class's input. known-files.txt and names.txt are both
# built from it, and those feed the orphans class too. A WordPress 5.3+
# oversized upload is the case that shows it: the attached file is
# "big-scaled.jpg" and the untouched "big.jpg" exists on disk only as the map's
# __original row. With the map gone, "big.jpg" is not a known file,
# canonical_original cannot rescue it (it strips -scaled, and the name on disk
# has no suffix), and it lands in doomed-orphans.txt together with every
# generated size - live images called orphans, under a return of 0. An
# untrustworthy size map is therefore fatal for the SITE, not for one class.
new_case "A4: an empty, unmarked size map refuses the site instead of orphaning a -scaled upload"
inv 1 "$OLD_DATE" 0 "2024/01/big-scaled.jpg"
registered thumbnail medium
att_ids 1
upload "2024/01/big-scaled.jpg"
upload "2024/01/big.jpg"                  # the untouched original: __original only
upload "2024/01/big-150x150.jpg"
upload "2024/01/big-300x200.jpg"
# sizemap.tsv is left empty AND the collector never emitted its marker.
SIZEMAP_COMPLETE=0
run_classify

assert_eq       "A4: the site is refused"                  "1"  "$RC"
assert_contains "A4: says it is refusing, and why"         "refusing to classify: the size map is empty" "$OUT"
assert_eq       "A4: the untouched original is not an orphan"   "no" "$(doomed_orph "2024/01/big.jpg")"
assert_eq       "A4: the 150x150 size is not an orphan"         "no" "$(doomed_orph "2024/01/big-150x150.jpg")"
assert_eq       "A4: the 300x200 size is not an orphan"         "no" "$(doomed_orph "2024/01/big-300x200.jpg")"
assert_eq       "A4: nothing at all is doomed as an orphan"     "0"  "$(n_lines "$WORK/doomed-orphans.txt")"
assert_eq       "A4: the uploads tree was never even walked"    "no" "$(walked)"

# The same with a map that is present but was cut short: attachment 1's rows
# made it out of PHP, attachment 2's did not.
new_case "A5: a truncated size map refuses the site too"
inv 1 "$OLD_DATE" 0 "2024/01/a-scaled.jpg"
inv 2 "$OLD_DATE" 0 "2024/01/b-scaled.jpg"
size 1 __original "a.jpg" "2024/01"
size 1 thumbnail  "a-150x150.jpg" "2024/01"
# attachment 2's rows never made it out of PHP: no __original, no sizes.
registered thumbnail
att_ids 1 2
upload "2024/01/a-scaled.jpg"; upload "2024/01/a.jpg"; upload "2024/01/a-150x150.jpg"
upload "2024/01/b-scaled.jpg"; upload "2024/01/b.jpg"; upload "2024/01/b-150x150.jpg"
SIZEMAP_COMPLETE=0
run_classify

assert_eq       "A5: the site is refused"                    "1"  "$RC"
assert_contains "A5: the wording still says incomplete, not empty" \
                "refusing to classify: the size map is incomplete" "$OUT"
assert_eq       "A5: b's untouched original is not an orphan" "no" "$(doomed_orph "2024/01/b.jpg")"
assert_eq       "A5: b's thumbnail is not an orphan"          "no" "$(doomed_orph "2024/01/b-150x150.jpg")"
assert_eq       "A5: nothing at all is doomed as an orphan"   "0"  "$(n_lines "$WORK/doomed-orphans.txt")"

# The refusal must fire on "the collector failed", never on "there is nothing
# to map" - a library of PDFs generates no sizes at all and its size map is
# legitimately empty. The completion marker is exactly what separates the two,
# and it is why collect_size_map prints one. This case guards against a fix
# that refuses on emptiness instead: the site carries on, and the thumbs class
# is skipped by the class-level guard as it was before.
new_case "A6: an empty size map that DID emit its marker is not refused"
inv 1 "$OLD_DATE" 0 "2024/01/manual.pdf"
registered thumbnail medium
att_ids 1
upload "2024/01/manual.pdf"
# sizemap.tsv is empty, but SIZEMAP_COMPLETE stays 1: the dump ran to the end.
run_classify

assert_eq           "A6: the site is not refused"           "0"   "$RC"
assert_not_contains "A6: and nothing says it refused"       "refusing to classify" "$OUT"
assert_eq           "A6: the run still walked the tree"     "yes" "$(walked)"
assert_contains     "A6: the thumbs class is still skipped" "skipping the thumbs class" "$OUT"

# ================================= B. the completeness marker itself

# The truncation above is only detectable because the PHP prints a terminator
# after its loop. Without it a partial dump is indistinguishable from a
# complete one, and a row count against the attachment count cannot tell them
# apart either (a library of PDFs legitimately generates no sizes at all).
new_case "B: collect_size_map detects a dump that was cut short"
WP_OUT=$'1\tthumbnail\ta-150x150.jpg\t2024/01'      # no terminator: PHP died
collect_size_map >/dev/null 2>&1
assert_eq "B: a dump with no completion marker is flagged" "0" "${SIZEMAP_COMPLETE:-unset}"
assert_eq "B: its rows are still kept for the other classes" "1" "$(n_lines "$WORK/sizemap.tsv")"

new_case "B2: a complete dump is accepted and the marker is stripped"
WP_OUT=$'1\tthumbnail\ta-150x150.jpg\t2024/01\n__SIZEMAP_COMPLETE__'
collect_size_map >/dev/null 2>&1
assert_eq "B2: the completion marker is recognised" "1" "${SIZEMAP_COMPLETE:-unset}"
assert_eq "B2: exactly the real rows survive"       "1" "$(n_lines "$WORK/sizemap.tsv")"
assert_eq "B2: the marker is not left in the map"   "no" \
          "$(yesno grep -q SIZEMAP_COMPLETE "$WORK/sizemap.tsv")"

# ======================================= C. upload variants are not orphans

# WordPress leaves the untouched original of an oversized upload on disk next
# to "<name>-scaled.<ext>", and the image editor writes "-rotated" and
# "-e<timestamp>" copies. None of them is in the size map and none is the
# attached file, so only canonical_original keeps them out of the orphan list.
new_case "C: -scaled, -rotated and -e<timestamp> variants of a known upload survive"
inv 1 "$OLD_DATE" 0 "2024/01/photo.jpg"
registered thumbnail
att_ids 1
upload "2024/01/photo.jpg"
upload "2024/01/photo-scaled.jpg"
upload "2024/01/photo-rotated.jpg"
upload "2024/01/photo-e1699999999.jpg"
run_classify

assert_eq "C: the original survives"            "no" "$(doomed_orph "2024/01/photo.jpg")"
assert_eq "C: the -scaled copy survives"        "no" "$(doomed_orph "2024/01/photo-scaled.jpg")"
assert_eq "C: the -rotated copy survives"       "no" "$(doomed_orph "2024/01/photo-rotated.jpg")"
assert_eq "C: the edited copy survives"         "no" "$(doomed_orph "2024/01/photo-e1699999999.jpg")"
assert_eq "C: no orphan at all in this tree"    "0"  "$(n_lines "$WORK/doomed-orphans.txt")"
assert_eq "C: and none of them is a stale thumb" "0" "$(n_lines "$WORK/doomed-thumbs.txt")"

# The size map's __original pseudo size covers the other spelling: the ATTACHED
# file is the -scaled one and the untouched original is only named in the
# metadata.
new_case "C2: the untouched original of a -scaled upload survives via __original"
inv 1 "$OLD_DATE" 0 "2024/01/big-scaled.jpg"
size 1 __original "big.jpg" "2024/01"
registered thumbnail
att_ids 1
upload "2024/01/big-scaled.jpg"
upload "2024/01/big.jpg"
run_classify

assert_eq "C2: the attached -scaled file survives" "no" "$(doomed_orph "2024/01/big-scaled.jpg")"
assert_eq "C2: the untouched original survives"    "no" "$(doomed_orph "2024/01/big.jpg")"
assert_eq "C2: __original is never a stale thumb"  "0"  "$(n_lines "$WORK/doomed-thumbs.txt")"

# After a crop or a rotate the edited image becomes the attached file, and the
# pre-edit original plus its old generated sizes survive only in
# _wp_attachment_backup_sizes, under WordPress's own "Restore original image"
# feature. Those old sizes are thumbnail-shaped and stored under a size name
# ("__backup") that appears in no list of registered sizes, so without the
# pseudo names in live-sizes.txt the thumbs class would take every one of them
# - and with them the ability to restore the original.
new_case "C3: a pre-edit backup size is not a stale thumbnail"
inv 1 "$OLD_DATE" 0 "2024/01/photo-e1699999999.jpg"
size 1 __backup  "photo-150x150.jpg" "2024/01"
size 1 thumbnail "photo-e1699999999-150x150.jpg" "2024/01"
registered thumbnail
att_ids 1
upload "2024/01/photo-e1699999999.jpg"
upload "2024/01/photo-e1699999999-150x150.jpg"
upload "2024/01/photo-150x150.jpg"
run_classify

assert_eq "C3: the backup size survives"        "no" "$(doomed_thumb "2024/01/photo-150x150.jpg")"
assert_eq "C3: the current size survives too"   "no" "$(doomed_thumb "2024/01/photo-e1699999999-150x150.jpg")"
assert_eq "C3: nothing is doomed"               "0"  "$(n_lines "$WORK/doomed-thumbs.txt")"

# ================================================= D. registered sizes stay

new_case "D: a thumbnail whose size name is still registered survives"
inv 1 "$OLD_DATE" 0 "2024/01/p.jpg"
size 1 thumbnail "p-150x150.jpg" "2024/01"
registered thumbnail medium large
att_ids 1
upload "2024/01/p.jpg"
upload "2024/01/p-150x150.jpg"
run_classify

assert_eq "D: the registered size survives" "no" "$(doomed_thumb "2024/01/p-150x150.jpg")"
assert_eq "D: nothing is doomed"            "0"  "$(n_lines "$WORK/doomed-thumbs.txt")"

new_case "E: a deregistered, unreferenced size IS doomed"
inv 1 "$OLD_DATE" 0 "2024/01/p.jpg"
size 1 thumbnail   "p-150x150.jpg" "2024/01"
size 1 legacy-hero "p-800x600.jpg" "2024/01"
registered thumbnail            # legacy-hero was dropped by the theme
att_ids 1
upload "2024/01/p.jpg"
upload "2024/01/p-150x150.jpg"
upload "2024/01/p-800x600.jpg"
run_classify

assert_eq "E: the deregistered size is doomed"   "yes" "$(doomed_thumb "2024/01/p-800x600.jpg")"
assert_eq "E: the registered one is not"         "no"  "$(doomed_thumb "2024/01/p-150x150.jpg")"
assert_eq "E: exactly one stale thumb"           "1"   "$(n_lines "$WORK/doomed-thumbs.txt")"
assert_eq "E: and it is not an orphan as well"   "0"   "$(n_lines "$WORK/doomed-orphans.txt")"

# A deregistered size whose file the content still references stays: this is
# what protects srcset candidates for sizes the theme no longer registers.
new_case "E2: a deregistered size still named in the content survives"
inv 1 "$OLD_DATE" 0 "2024/01/p.jpg"
size 1 legacy-hero "p-800x600.jpg" "2024/01"
registered thumbnail
hay '<img srcset="/wp-content/uploads/2024/01/p-800x600.jpg 800w">'
att_ids 1
upload "2024/01/p.jpg"
upload "2024/01/p-800x600.jpg"
run_classify

assert_eq "E2: a referenced deregistered size survives" "no" "$(doomed_thumb "2024/01/p-800x600.jpg")"
assert_eq "E2: nothing is doomed"                       "0"  "$(n_lines "$WORK/doomed-thumbs.txt")"

# ====================================== F. one file, two size names

# Two registered sizes with identical dimensions collapse onto the same file.
# Dooming it because ONE of its size names is dead would delete a file the
# other, live size still serves.
new_case "F: a file shared by a live and a dead size name survives"
inv 1 "$OLD_DATE" 0 "2024/01/p.jpg"
size 1 medium     "p-300x200.jpg" "2024/01"
size 1 old-medium "p-300x200.jpg" "2024/01"
registered medium            # old-medium is gone, medium is not
att_ids 1
upload "2024/01/p.jpg"
upload "2024/01/p-300x200.jpg"
run_classify

assert_eq "F: the shared file survives" "no" "$(doomed_thumb "2024/01/p-300x200.jpg")"
assert_eq "F: nothing is doomed"        "0"  "$(n_lines "$WORK/doomed-thumbs.txt")"

new_case "F2: the same file with BOTH size names dead is doomed"
inv 1 "$OLD_DATE" 0 "2024/01/p.jpg"
size 1 old-medium "p-300x200.jpg" "2024/01"
size 1 older-mid  "p-300x200.jpg" "2024/01"
registered medium
att_ids 1
upload "2024/01/p.jpg"
upload "2024/01/p-300x200.jpg"
run_classify

assert_eq "F2: with no live size left it is doomed" "yes" "$(doomed_thumb "2024/01/p-300x200.jpg")"

# ============================== G. exclusions: plugin dirs and infrastructure

new_case "G: EXCLUDE_UPLOAD_DIRS and WordPress's own files are never orphans"
inv 1 "$OLD_DATE" 0 "2024/01/p.jpg"
registered thumbnail
att_ids 1
upload "2024/01/p.jpg"
upload "index.php"                        # every uploads dir ships one
upload "2024/01/index.html"
upload "2024/01/web.config"
upload ".htaccess"                        # dotfile: WooCommerce download guard
upload "elementor/css/post-7.css"         # excluded at the root
upload "2024/01/elementor/thumb.jpg"      # and at any depth
upload "woocommerce_uploads/invoice.pdf"
upload "2024/01/stray.jpg"                # a genuine orphan, the control
run_classify

assert_eq "G: uploads/index.php is not an orphan"     "no" "$(doomed_orph "index.php")"
assert_eq "G: a nested index.html is not an orphan"   "no" "$(doomed_orph "2024/01/index.html")"
assert_eq "G: web.config is not an orphan"            "no" "$(doomed_orph "2024/01/web.config")"
assert_eq "G: a dotfile is not an orphan"             "no" "$(doomed_orph ".htaccess")"
assert_eq "G: an excluded dir at the root is skipped" "no" "$(doomed_orph "elementor/css/post-7.css")"
assert_eq "G: an excluded dir at depth is skipped"    "no" "$(doomed_orph "2024/01/elementor/thumb.jpg")"
assert_eq "G: woocommerce_uploads is skipped"         "no" "$(doomed_orph "woocommerce_uploads/invoice.pdf")"
assert_eq "G: the genuine orphan IS reported"         "yes" "$(doomed_orph "2024/01/stray.jpg")"
assert_eq "G: and it is the only one"                 "1"  "$(n_lines "$WORK/doomed-orphans.txt")"

# ==================================================== H. the age cutoff

new_case "H: an attachment newer than the cutoff is never doomed"
inv 1 "$OLD_DATE" 0 "2024/01/old.jpg"
inv 2 "$NEW_DATE" 0 "2024/01/new.jpg"
registered thumbnail
att_ids 999                    # a non-empty ID set that names neither of them
upload "2024/01/old.jpg"
upload "2024/01/new.jpg"
run_classify

assert_eq "H: the old unreferenced attachment is doomed" "yes" "$(doomed_att "2024/01/old.jpg")"
assert_eq "H: the recent one is not"                     "no"  "$(doomed_att "2024/01/new.jpg")"
assert_eq "H: exactly one doomed attachment"             "1"   "$(n_lines "$WORK/doomed-attachments.tsv")"
# Its file must not come back as an orphan through the other door either.
assert_eq "H: the recent file is not an orphan"          "no"  "$(doomed_orph "2024/01/new.jpg")"

# ======================================= I. the two ways of being referenced

new_case "I: a reference by ID and a reference by name both protect an attachment"
inv 1 "$OLD_DATE" 0 "2024/01/by-id.jpg"
inv 2 "$OLD_DATE" 0 "2024/01/by-name.jpg"
inv 3 "$OLD_DATE" 0 "2024/01/nobody.jpg"
registered thumbnail
att_ids 1                                  # a featured image / ACF field
hay '<img class="wp-image-9" src="/wp-content/uploads/2024/01/by-name.jpg">'
upload "2024/01/by-id.jpg"; upload "2024/01/by-name.jpg"; upload "2024/01/nobody.jpg"
run_classify

assert_eq "I: referenced by ID survives"    "no"  "$(doomed_att "2024/01/by-id.jpg")"
assert_eq "I: referenced by name survives"  "no"  "$(doomed_att "2024/01/by-name.jpg")"
assert_eq "I: the unreferenced one is doomed" "yes" "$(doomed_att "2024/01/nobody.jpg")"

new_case "I2: a percent-encoded reference protects the upload it names"
inv 1 "$OLD_DATE" 0 "2024/01/my photo.jpg"
registered thumbnail
att_ids 999
hay '<img src="/wp-content/uploads/2024/01/my%20photo.jpg">'
upload "2024/01/my photo.jpg"
run_classify

assert_eq "I2: the encoded spelling protects the attachment" "no" "$(doomed_att "my photo.jpg")"
assert_eq "I2: and the file is not an orphan"                "no" "$(doomed_orph "2024/01/my photo.jpg")"

# ============================ J. Critical 1: a collector that failed is not truth

new_case "J: an empty ID set skips the attachments class"
inv 1 "$OLD_DATE" 0 "2024/01/p.jpg"
registered thumbnail
upload "2024/01/p.jpg"
# ids.txt is left empty: the queries that build it failed.
run_classify

assert_eq       "J: no attachment is doomed"       "0" "$(n_lines "$WORK/doomed-attachments.tsv")"
assert_contains "J: says why"                      "ids.txt is empty" "$OUT"

# The -s guard above does NOT cover the more likely failure: one of the two ID
# queries fails and the other still fills the file. The set then looks like a
# real answer, and every featured image whose ID was in the missing half is
# reported as unused. collect_id_set records that with $IDS_OK.
new_case "K: a partially built ID set skips the attachments class too"
inv 1 "$OLD_DATE" 0 "2024/01/p.jpg"
registered thumbnail
att_ids 4321                     # non-empty, but from only one of the queries
upload "2024/01/p.jpg"
IDS_OK=0
run_classify

assert_eq       "K: no attachment is doomed"           "0" "$(n_lines "$WORK/doomed-attachments.tsv")"
assert_contains "K: says the ID set is incomplete"     "ids.txt is incomplete" "$OUT"
# The same run must still be allowed to do the disk classes: they do not read
# ids.txt at all.
assert_eq       "K: the file classes still ran"        "yes" "$(walked)"

new_case "K2: an empty registered-size list skips the thumbs class"
inv 1 "$OLD_DATE" 0 "2024/01/p.jpg"
size 1 legacy "p-800x600.jpg" "2024/01"
att_ids 1
upload "2024/01/p.jpg"; upload "2024/01/p-800x600.jpg"
# registered.txt is left empty: `wp media image-size` failed.
run_classify

assert_eq       "K2: nothing is doomed as a thumb" "0" "$(n_lines "$WORK/doomed-thumbs.txt")"
assert_contains "K2: says why"                     "registered.txt is empty" "$OUT"

# ================================== L. --only attachments skips the disk sweep

# Every branch of the file loop writes to doomed-orphans.txt or
# doomed-thumbs.txt, so under --only attachments the walk of the whole uploads
# tree produces nothing at all - on a 200k file tree, for nothing.
new_case "L: --only attachments does not walk the uploads tree"
inv 1 "$OLD_DATE" 0 "2024/01/p.jpg"
registered thumbnail
att_ids 999
upload "2024/01/p.jpg"
upload "2024/01/stray.jpg"
ONLY_CLASS="attachments"
run_classify

assert_eq "L: the uploads tree was never walked" "no"  "$(walked)"
assert_eq "L: no orphan was produced"            "0"   "$(n_lines "$WORK/doomed-orphans.txt")"
assert_eq "L: the attachments class still ran"   "yes" "$(doomed_att "2024/01/p.jpg")"

new_case "L2: --only orphans still walks it"
inv 1 "$OLD_DATE" 0 "2024/01/p.jpg"
registered thumbnail
att_ids 999
upload "2024/01/p.jpg"
upload "2024/01/stray.jpg"
# shellcheck disable=SC2034  # read by classify(), in the sourced script
ONLY_CLASS="orphans"
run_classify

assert_eq "L2: the tree was walked"             "yes" "$(walked)"
assert_eq "L2: the orphan was found"            "yes" "$(doomed_orph "2024/01/stray.jpg")"
assert_eq "L2: no attachment was doomed"        "0"   "$(n_lines "$WORK/doomed-attachments.tsv")"

# =============================== M. Critical 1: the haystack's required sources

# A query that fails silently strips references out of the haystack, and every
# reference it loses turns some file into a false orphan - the one direction
# the classification is forbidden to err in. posts, postmeta and options carry
# essentially every reference on a site, so losing one of them is fatal for
# that site; termmeta and usermeta are the two that are genuinely optional.
new_case "M: a failed posts query is fatal for the site"
WP_FAIL_MATCH="post_content"
collect_haystack >/dev/null 2>&1
assert_eq "M: collect_haystack reports failure" "1" "$?"

new_case "M2: a failed postmeta query is fatal too"
WP_FAIL_MATCH="wp_postmeta"
OUT="$(collect_haystack 2>&1)"; RC=$?
assert_eq       "M2: reports failure"        "1" "$RC"
assert_contains "M2: says it was required"   "a required haystack query failed" "$OUT"

new_case "M3: a failed options query is fatal too"
WP_FAIL_MATCH="option_value"
collect_haystack >/dev/null 2>&1
assert_eq "M3: reports failure" "1" "$?"

new_case "M4: a failed termmeta query is survivable"
WP_FAIL_MATCH="termmeta"
OUT="$(collect_haystack 2>&1)"; RC=$?
assert_eq       "M4: returns success"              "0" "$RC"
assert_contains "M4: says it carried on"           "an optional haystack query failed, continuing" "$OUT"
assert_eq       "M4: the run did not stop at the failing query" "6" "$(n_lines "$WP_LOG")"

new_case "M5: a failed usermeta query is survivable"
WP_FAIL_MATCH="usermeta"
collect_haystack >/dev/null 2>&1
assert_eq "M5: returns success" "0" "$?"

new_case "M6: all six queries succeeding is a success"
collect_haystack >/dev/null 2>&1
assert_eq "M6: returns success"     "0" "$?"
assert_eq "M6: all six ran"         "6" "$(n_lines "$WP_LOG")"

# ================================ N. Critical 1: collect_id_set's two queries

# Neither query has any error handling to speak of in the version this suite
# was written against: both can fail completely silently, and the surviving one
# still fills ids.txt, so the "empty ids.txt" guard never fires.
new_case "N: a failed options ID query is recorded even though ids.txt fills up"
WP_OUT="7"
WP_FAIL_MATCH="option_name"
collect_id_set >/dev/null 2>&1
assert_eq       "N: IDS_OK says the set is incomplete" "0" "${IDS_OK:-unset}"
assert_eq       "N: ids.txt is NOT empty, so -s cannot catch this" "yes" \
                "$(yesno test -s "$WORK/ids.txt")"

new_case "N2: a failed postmeta ID query is recorded as well"
WP_OUT="7"
WP_FAIL_MATCH="meta_value REGEXP"
# Not `OUT=$(collect_id_set)`: a command substitution is a subshell, and
# $IDS_OK set inside one never reaches the assertion.
collect_id_set > "$CASE_DIR/out.txt" 2>&1
OUT="$(cat "$CASE_DIR/out.txt")"
assert_eq       "N2: IDS_OK says the set is incomplete" "0" "${IDS_OK:-unset}"
assert_contains "N2: names the query"                   "postmeta ID query failed" "$OUT"

new_case "N3: two working queries leave IDS_OK alone"
WP_OUT="7"
collect_id_set >/dev/null 2>&1
assert_eq "N3: IDS_OK stays set"      "1" "${IDS_OK:-unset}"
assert_eq "N3: the ID set was built"  "1" "$(n_lines "$WORK/ids.txt")"

# ============================================= O. the path-component helper

# Three places build the directory component of a path; only two of them used
# to normalise dirname's "." for a root-level upload, which put a "./" into the
# quarantine manifest and made restore_chown_path chown the uploads directory
# itself. One helper, so they cannot disagree.
section "O: rel_dir normalises a path with no directory component"
assert_eq "O: a root-level upload has no directory" "" "$(rel_dir 'photo.jpg')"
assert_eq "O: a normal upload keeps its directory"  "2024/01" "$(rel_dir '2024/01/photo.jpg')"
assert_eq "O: an absolute path keeps its directory" "/a/b" "$(rel_dir '/a/b/c.jpg')"

# ---------------------------------------------------------------- summary

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
