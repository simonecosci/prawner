#!/usr/bin/env bash
#
# tests/quarantine.sh - dependency-free tests for the removal path of
#                       bin/wp-media-clean.sh
#
# quarantine_site() is the half of the program that moves files and deletes
# database rows. Until this file existed it had zero assertions on it, and the
# review that followed found that every path out of it returned 0: a run in
# which the dump gate refused, or every move failed, or every `wp post delete`
# failed, still put the site in OK and still exited 0 - with the log reporting
# the number of files that were ELIGIBLE to move as though they had moved.
#
# The governing property here is "no silent success": a run that did not fully
# do what it claims must not report ok and exit 0. Most of the assertions below
# are that property, or the counting that makes the log honest about it.
#
# Stubs: wp_run only (a dev machine has no wp-cli, and "the dump came back
# truncated" is exactly what these cases are about). mv, mkdir, find and rmdir
# are real - half of qmove exists because GNU `mv -n` exits 0 when it silently
# refuses to clobber, and a stubbed mv would only ever prove the stub. The one
# case that needs a move to fail wraps the real mv rather than replacing it.
#
#   bash tests/quarantine.sh
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

# The line that tells the operator the move happened. A run that did not do
# what it was asked must not print it.
OK_LINE="[ok]"

# Most of what new_case assigns is read by the sourced script, not by this
# file, so the static check cannot see the use.
# shellcheck disable=SC2034
new_case() {
  CASE_N=$((CASE_N + 1))
  section "$1"
  CASE_DIR="$SANDBOX/case$CASE_N"
  WORK="$CASE_DIR/work"
  SITE_PATH="$CASE_DIR/site"
  UPLOADS_DIR="$SITE_PATH/wp-content/uploads"
  QUARANTINE_ROOT="$CASE_DIR/quarantine"
  SITE_SLUG="site"
  SITE_NAME="example.com"
  STAMP="20260101-000000"
  QDIR="$QUARANTINE_ROOT/$SITE_SLUG/$STAMP"
  PREFIX="wp_"
  KEEP_QUARANTINE=3
  LOG_FILE="$CASE_DIR/run.log"
  WP_LOG="$CASE_DIR/wp.log"
  DUMP_MODE="good"
  THUMB_DUMP=""
  WP_DELETE_RC=0
  WP_EVAL_RC=0
  MV_FAIL_MATCH=""
  mkdir -p "$WORK" "$UPLOADS_DIR" "$QUARANTINE_ROOT"
  : > "$WORK/inventory.tsv"; : > "$WORK/sizemap.tsv"
  : > "$WORK/doomed-attachments.tsv"
  : > "$WORK/doomed-orphans.txt"
  : > "$WORK/doomed-thumbs.txt"
  : > "$LOG_FILE"; : > "$WP_LOG"
}

# doomed_att <id> <rel>            an attachment classify() marked for removal
doomed_att() { printf '%s\t%s\n' "$1" "$2" >> "$WORK/doomed-attachments.tsv"; }
# size <id> <size name> <file> <dir>
size() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$WORK/sizemap.tsv"; }
# doomed_orphan <rel> / doomed_thumb <rel>   paths relative to the uploads dir
doomed_orphan() { printf '%s\n' "$UPLOADS_DIR/$1" >> "$WORK/doomed-orphans.txt"; }
doomed_thumb()  { printf '%s\n' "$UPLOADS_DIR/$1" >> "$WORK/doomed-thumbs.txt"; }

# upload <rel> [content]           a real file under the uploads directory
upload() {
  mkdir -p "$(dirname "$UPLOADS_DIR/$1")"
  printf '%s\n' "${2:-content-of-$1}" > "$UPLOADS_DIR/$1"
}

# --------------------------------------------------------------- the stubs

# A mysqldump-shaped dump. mysqldump writes a comment header before any row,
# so "non-empty" is not the same as "carries rows" - which is what the gate in
# quarantine_site is about.
dump_good()     { printf -- '-- MySQL dump 10.13\n'; printf 'INSERT INTO `wp_x` VALUES (1,2,3);\n'; printf -- '-- Dump completed on 2026-01-01\n'; }
dump_noinsert() { printf -- '-- MySQL dump 10.13\n'; }

wp_run() {
  local args="$*"
  printf '%s\n' "$args" >> "$WP_LOG"
  case "$args" in
    # The thumbnail-metadata dump: whatever the case wants it to contain.
    *"_wp_attachment_metadata"*)
      printf '%s' "$THUMB_DUMP"; return 0 ;;
    "db export"*)
      case "$DUMP_MODE" in
        good)     dump_good ;;
        empty)    : ;;
        noinsert) dump_noinsert ;;
      esac
      return 0 ;;
    "post delete"*) return "$WP_DELETE_RC" ;;
    "eval"*)        return "$WP_EVAL_RC" ;;
  esac
  return 0
}

# Real mv, wrapped so one case can make a single move fail without touching
# any of the others. `mv -n` exiting 0 on a silent skip is the trap qmove's
# post-move filesystem check exists for, so mv itself stays real.
mv() {
  if [[ -n "$MV_FAIL_MATCH" && "$*" == *"$MV_FAIL_MATCH"* ]]; then
    return 1
  fi
  command mv "$@"
}

# --------------------------------------------------------------- observers

run_quarantine() { OUT="$(quarantine_site 2>&1)"; RC=$?; }

yesno()      { if "$@"; then echo yes; else echo no; fi; }
present()    { yesno test -e "$1"; }
n_lines()    { if [[ -s "$1" ]]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }
wp_called()  { yesno grep -Fq -- "$1" "$WP_LOG"; }
in_manifest(){ yesno grep -Fq -- "$1" "$QDIR/manifest.tsv"; }
quarantined(){ yesno test -e "$QDIR/files/wp-content/uploads/$1"; }
still_on_disk() { yesno test -e "$UPLOADS_DIR/$1"; }

# ================================================== A. the happy path

new_case "A: a clean run moves the files, deletes the row and says how to undo it"
doomed_att 11 "2024/01/a.jpg"
size 11 thumbnail "a-150x150.jpg" "2024/01"
upload "2024/01/a.jpg"
upload "2024/01/a-150x150.jpg"
doomed_orphan "2024/01/stray.jpg"; upload "2024/01/stray.jpg"
run_quarantine

assert_eq       "A: succeeds"                          "0" "$RC"
assert_eq       "A: the attachment file was moved"     "yes" "$(quarantined "2024/01/a.jpg")"
assert_eq       "A: its generated size was moved too"  "yes" "$(quarantined "2024/01/a-150x150.jpg")"
assert_eq       "A: the orphan was moved"              "yes" "$(quarantined "2024/01/stray.jpg")"
assert_eq       "A: nothing is left at the site"       "no"  "$(still_on_disk "2024/01/a.jpg")"
assert_eq       "A: three manifest entries"            "3"   "$(n_lines "$QDIR/manifest.tsv")"
assert_eq       "A: the row was deleted"               "yes" "$(wp_called "post delete 11")"
assert_contains "A: counts the attachment as done"     "quarantined 1 attachments" "$OUT"
assert_contains "A: counts the orphan as done"         "quarantined 1 orphan files" "$OUT"
assert_contains "A: reports the quarantine set"        "$OK_LINE" "$OUT"
# The tool's entire safety story is that the move is reversible, and this is
# the one moment the operator is looking at the output.
assert_contains "A: prints the exact restore command"  \
                "wp-media-clean.sh --restore 20260101-000000 --site example.com" "$OUT"

# ======================================= B. the dump gate must be a failure

# The row dump is the only copy of what `wp post delete` is about to destroy.
# When it cannot be trusted the whole attachments class is skipped - and that
# skip used to be reported as a completely successful run.
new_case "B: a dump that came back empty skips the class AND fails the run"
doomed_att 11 "2024/01/a.jpg"
upload "2024/01/a.jpg"
DUMP_MODE="empty"
run_quarantine

assert_eq       "B: returns non-zero"                 "1" "$RC"
assert_contains "B: says the attachments were left alone" "attachments left untouched" "$OUT"
assert_eq       "B: the file is still at the site"    "yes" "$(still_on_disk "2024/01/a.jpg")"
assert_eq       "B: no row was deleted"               "no"  "$(wp_called "post delete")"
assert_not_contains "B: no success line"              "$OK_LINE" "$OUT"
assert_contains "B: says nothing was quarantined"     "nothing was quarantined" "$OUT"

new_case "B2: a dump with a header but no rows fails the same way"
doomed_att 11 "2024/01/a.jpg"
upload "2024/01/a.jpg"
DUMP_MODE="noinsert"
run_quarantine

assert_eq       "B2: returns non-zero"                "1" "$RC"
assert_contains "B2: says the dump captured no rows"  "captured no rows" "$OUT"
assert_eq       "B2: the file is still at the site"   "yes" "$(still_on_disk "2024/01/a.jpg")"
assert_eq       "B2: no row was deleted"              "no"  "$(wp_called "post delete")"
assert_not_contains "B2: no success line"             "$OK_LINE" "$OUT"

# ============================= C. a failed move must block the row deletion

# A file that failed to move is still on disk and its row is the only record
# of it; deleting the post here would leave wp_delete_attachment nothing to
# unlink and no way back.
new_case "C: a failed move blocks wp post delete and fails the run"
doomed_att 11 "2024/01/a.jpg"
size 11 thumbnail "a-150x150.jpg" "2024/01"
upload "2024/01/a.jpg"
upload "2024/01/a-150x150.jpg"
MV_FAIL_MATCH="a-150x150.jpg"
run_quarantine

assert_eq       "C: returns non-zero"                     "1" "$RC"
assert_eq       "C: the row was NOT deleted"              "no" "$(wp_called "post delete 11")"
assert_contains "C: says why the row was left in place"   "not every file for attachment 11 moved" "$OUT"
assert_contains "C: counts zero attachments done"         "quarantined 0 attachments" "$OUT"
assert_eq       "C: the file that could not move is still there" "yes" "$(still_on_disk "2024/01/a-150x150.jpg")"

new_case "C2: a failed wp post delete fails the run"
doomed_att 11 "2024/01/a.jpg"
upload "2024/01/a.jpg"
WP_DELETE_RC=1
run_quarantine

assert_eq       "C2: returns non-zero"                "1" "$RC"
assert_contains "C2: names the failed delete"         "wp post delete 11 failed" "$OUT"
assert_contains "C2: counts zero attachments done"    "quarantined 0 attachments" "$OUT"
assert_contains "C2: warns that the pass was incomplete" "did not do everything it was asked to" "$OUT"

# ============================== D. the counts must be of what actually happened

# doomed-orphans.txt says what was ELIGIBLE. A log that reports its line count
# after a loop that discarded every qmove result claims work that never
# happened - on the exact runs where an operator most needs the truth.
new_case "D: the orphan count is of moves that happened, not of eligible files"
doomed_orphan "2024/01/one.jpg";  upload "2024/01/one.jpg"
doomed_orphan "2024/01/two.jpg"   # never created: qmove finds nothing to move
run_quarantine

assert_eq       "D: returns non-zero"                "1" "$RC"
assert_contains "D: counts only the move that happened" "quarantined 1 orphan files" "$OUT"
assert_not_contains "D: does not claim both"         "quarantined 2 orphan files" "$OUT"
assert_eq       "D: one manifest entry"              "1" "$(n_lines "$QDIR/manifest.tsv")"

new_case "D2: the thumbnail count is of moves that happened too"
size 11 legacy "t-800x600.jpg" "2024/01"
size 12 legacy "u-800x600.jpg" "2024/01"
doomed_thumb "2024/01/t-800x600.jpg"; upload "2024/01/t-800x600.jpg"
doomed_thumb "2024/01/u-800x600.jpg"  # never created
THUMB_DUMP=$'INSERT INTO `wp_postmeta` VALUES (1,11,\'_wp_attachment_metadata\',\'a:1:{}\');\n'
run_quarantine

assert_eq       "D2: returns non-zero"                  "1" "$RC"
assert_contains "D2: counts only the move that happened" "quarantined 1 stale thumbnails" "$OUT"
assert_not_contains "D2: does not claim both"           "quarantined 2 stale thumbnails" "$OUT"

# ====================== E. the metadata eval is gated per attachment ID

# One dump covers every affected ID at once, so a single surviving INSERT used
# to admit the unset() for ALL of them. A dump truncated partway then left
# every later attachment with its metadata unset and no captured row to put it
# back from - and by that point the files are already off the site, so this is
# the step that makes the move irreversible.
new_case "E: an ID the metadata dump does not corroborate is not unset"
size 11 legacy "t-800x600.jpg" "2024/01"
size 12 legacy "u-800x600.jpg" "2024/01"
doomed_thumb "2024/01/t-800x600.jpg"; upload "2024/01/t-800x600.jpg"
doomed_thumb "2024/01/u-800x600.jpg"; upload "2024/01/u-800x600.jpg"
# The dump died after attachment 11's row: 12 is in the WHERE clause and not
# in the output.
THUMB_DUMP=$'-- MySQL dump 10.13\nINSERT INTO `wp_postmeta` VALUES (1,11,\'_wp_attachment_metadata\',\'a:1:{}\');\n'
run_quarantine

assert_eq       "E: returns non-zero"                    "1" "$RC"
assert_contains "E: names the attachment it will not touch" "does not corroborate attachment 12" "$OUT"
assert_eq       "E: only the corroborated ID is handed to the eval" "1" \
                "$(n_lines "$QDIR/rows/thumb-sizes.tsv")"
assert_eq       "E: and it is the corroborated one"      "yes" \
                "$(yesno grep -q '^11	' "$QDIR/rows/thumb-sizes.tsv")"
assert_eq       "E: attachment 12 is not in the applied list" "no" \
                "$(yesno grep -q '^12	' "$QDIR/rows/thumb-sizes.tsv")"
# Both files did move: the gate is about the metadata edit, not the move, and
# both are restorable because the files and the dump are both in the set.
assert_eq       "E: both thumbnails were still moved"    "yes" "$(quarantined "2024/01/u-800x600.jpg")"

new_case "E2: a metadata dump with no rows at all leaves every ID alone"
size 11 legacy "t-800x600.jpg" "2024/01"
doomed_thumb "2024/01/t-800x600.jpg"; upload "2024/01/t-800x600.jpg"
THUMB_DUMP=$'-- MySQL dump 10.13\n'
run_quarantine

assert_eq       "E2: returns non-zero"              "1" "$RC"
assert_eq       "E2: the eval never ran"            "no" "$(wp_called "eval")"
assert_eq       "E2: nothing was handed to it"      "0" "$(n_lines "$QDIR/rows/thumb-sizes.tsv")"
assert_eq       "E2: the thumbnail did move and is restorable" "yes" "$(quarantined "2024/01/t-800x600.jpg")"

new_case "E3: a fully corroborated dump runs the eval and succeeds"
size 11 legacy "t-800x600.jpg" "2024/01"
doomed_thumb "2024/01/t-800x600.jpg"; upload "2024/01/t-800x600.jpg"
THUMB_DUMP=$'-- MySQL dump 10.13\nINSERT INTO `wp_postmeta` VALUES (1,11,\'_wp_attachment_metadata\',\'a:1:{}\');\n'
run_quarantine

assert_eq       "E3: succeeds"                      "0" "$RC"
assert_eq       "E3: the eval ran"                  "yes" "$(wp_called "eval")"
assert_contains "E3: counts the thumbnail"          "quarantined 1 stale thumbnails" "$OUT"

new_case "E4: a failed metadata eval is a failure, not an ok"
size 11 legacy "t-800x600.jpg" "2024/01"
doomed_thumb "2024/01/t-800x600.jpg"; upload "2024/01/t-800x600.jpg"
THUMB_DUMP=$'INSERT INTO `wp_postmeta` VALUES (1,11,\'_wp_attachment_metadata\',\'a:1:{}\');\n'
WP_EVAL_RC=1
run_quarantine

assert_eq       "E4: returns non-zero"              "1" "$RC"
assert_contains "E4: says the metadata is stale"    "cannot clean the thumbnail metadata" "$OUT"

# ============================ F. a quarantine directory that cannot be created

# With $QUARANTINE_ROOT unwritable, mkdir -p fails, manifest.tsv is never
# created, every qmove warns, and the teardown branch reports "nothing to
# quarantine" - which used to be an ok and an exit 0 over a run that moved
# nothing at all. Here the root's parent is a regular file, which makes the
# mkdir fail identically on every platform and needs no root to set up.
new_case "F: a quarantine root that cannot be created fails the run"
doomed_att 11 "2024/01/a.jpg"
upload "2024/01/a.jpg"
printf 'not a directory\n' > "$CASE_DIR/blocked"
QUARANTINE_ROOT="$CASE_DIR/blocked/wp-media"
run_quarantine

assert_eq       "F: returns non-zero"                 "1" "$RC"
assert_contains "F: says it cannot create the set"    "cannot create the quarantine directory" "$OUT"
assert_not_contains "F: no success line"              "$OK_LINE" "$OUT"
assert_eq       "F: the file was not touched"         "yes" "$(still_on_disk "2024/01/a.jpg")"
assert_eq       "F: no row was deleted"               "no"  "$(wp_called "post delete")"

# ================== G. a failed run must not leave a husk in the quarantine

# qmove creates the files/wp-content/uploads/... skeleton before it moves
# anything, so a run in which every move failed leaves an empty tree standing.
# It is then the newest entry under the site's quarantine directory, and the
# next successful run's prune_quarantine counts it towards KEEP_QUARANTINE and
# deletes the oldest REAL set to make room: a failed run silently costs a
# recovery point.
new_case "G: a run in which everything failed leaves no husk behind"
doomed_orphan "2024/01/one.jpg"; upload "2024/01/one.jpg"
doomed_orphan "2024/01/two.jpg"; upload "2024/01/two.jpg"
MV_FAIL_MATCH="/"        # every move fails
run_quarantine

assert_eq       "G: returns non-zero"                 "1" "$RC"
assert_eq       "G: no empty skeleton survives"       "no" "$(present "$QDIR/files/wp-content/uploads")"
assert_eq       "G: the quarantine set itself is gone" "no" "$(present "$QDIR")"
assert_eq       "G: both files are still at the site" "yes" "$(still_on_disk "2024/01/two.jpg")"
assert_not_contains "G: no success line"              "$OK_LINE" "$OUT"
assert_contains "G: says every operation failed"      "nothing was quarantined" "$OUT"

new_case "G2: a run with genuinely nothing to do is a success"
run_quarantine

assert_eq       "G2: succeeds"                        "0" "$RC"
assert_contains "G2: says there was nothing to do"    "nothing to quarantine" "$OUT"
assert_not_contains "G2: does not claim a failure"    "every operation failed" "$OUT"
assert_eq       "G2: the empty set was cleaned up"    "no" "$(present "$QDIR")"

# A failed run and an empty run both end with an empty manifest, and only one
# of them is good news: they must not print the same thing.
new_case "G3: a failed run and an empty run do not report the same thing"
doomed_orphan "2024/01/one.jpg"; upload "2024/01/one.jpg"
MV_FAIL_MATCH="/"
run_quarantine
FAILED_OUT="$OUT"; FAILED_RC="$RC"
new_case "G3b: (the empty run it must not look like)"
run_quarantine

assert_eq "G3: the failed run returns non-zero"       "1" "$FAILED_RC"
assert_eq "G3: the empty run returns zero"            "0" "$RC"
assert_eq "G3: their reports differ"                  "no" "$(yesno test "$FAILED_OUT" = "$OUT")"

# ================================ H. the manifest path for a root-level upload

# With uploads_use_yearmonth_folders off an upload has no directory component
# at all. The manifest is what --restore replays, and a "./" in the middle of a
# recorded path makes restore_chown_path resolve its dirname to $UPLOADS_DIR
# itself and chown the uploads directory - the very thing its containment check
# exists to prevent.
new_case "H: a root-level upload is recorded without a ./ path component"
doomed_att 11 "photo.jpg"
size 11 thumbnail "photo-150x150.jpg" ""
upload "photo.jpg"
upload "photo-150x150.jpg"
run_quarantine

assert_eq "H: succeeds"                              "0" "$RC"
assert_eq "H: the original is recorded cleanly"      "yes" \
          "$(in_manifest "wp-content/uploads/photo.jpg")"
assert_eq "H: the generated size is recorded cleanly" "yes" \
          "$(in_manifest "wp-content/uploads/photo-150x150.jpg")"
assert_eq "H: no ./ anywhere in the manifest"        "no" \
          "$(yesno grep -q '/\./' "$QDIR/manifest.tsv")"
assert_eq "H: no // anywhere in the manifest"        "no" \
          "$(yesno grep -q '//' "$QDIR/manifest.tsv")"
# And the file really is where the manifest says it is, so a restore finds it.
assert_eq "H: the size landed at the recorded path"  "yes" "$(quarantined "photo-150x150.jpg")"

# ---------------------------------------------------------------- summary

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
