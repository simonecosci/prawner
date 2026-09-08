#!/usr/bin/env bash
#
# tests/restore.sh - dependency-free tests for the restore path of
#                    bin/wp-media-clean.sh
#
# restore_site is the recovery path. It runs after the tool has already
# quarantined something it should not have, on a site that is already in a bad
# state, and the line it prints on success invites the operator to delete the
# only remaining copy of their files. Its governing property is therefore "no
# silent success": it must never report ok and return 0 on a restore that did
# not fully happen. Nearly every assertion below exists to hold that property,
# or one of the properties it rests on, down.
#
# tests/run.sh covers the pure string functions and deliberately touches no
# filesystem. These tests need one, plus three things a developer machine will
# not have: chown, real ownership metadata, and wp-cli. chown, stat and wp_run
# are replaced by shell functions - a function shadows an external command for
# the rest of the file - so ownership is modelled in a small text registry and
# no test needs root or a database. Everything else is real. That matters most
# for mv: half of this code exists because GNU `mv -n` exits 0 when it
# silently refuses to clobber an existing destination, and a stubbed mv would
# only ever prove the stub.
#
#   bash tests/restore.sh
#
# WMC_SCRIPT points the suite at a different copy of the script. That is how
# these assertions were checked to actually discriminate: each one was run
# against an earlier commit, or against a copy with the relevant fix removed,
# and seen to fail there.
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

# new_case <label> [uploads-subpath]
# Builds a fresh site tree and quarantine set and points every global the
# restore path reads at it. Production sets these in load_site(); nothing here
# calls load_site, because it needs wp-cli and a live database.
new_case() {
  CASE_N=$((CASE_N + 1))
  section "$1"
  CASE_DIR="$SANDBOX/case$CASE_N"
  SITE_PATH="$CASE_DIR/site"
  UPLOADS_REL="${2:-wp-content/uploads}"
  UPLOADS_DIR="$SITE_PATH/$UPLOADS_REL"
  SITE_OWNER="wpuser"
  SITE_GROUP="wpgroup"
  QUARANTINE_ROOT="$CASE_DIR/quarantine"
  SITE_SLUG="site"
  SITE_NAME="site"
  RESTORE_STAMP="20260101-000000"
  QDIR="$QUARANTINE_ROOT/$SITE_SLUG/$RESTORE_STAMP"
  LOG_FILE="$CASE_DIR/run.log"
  CHOWN_LOG="$CASE_DIR/chown-args.log"
  CHOWN_TARGETS="$CASE_DIR/chown-targets.log"
  WP_LOG="$CASE_DIR/wp.log"
  OWN_DB="$CASE_DIR/owners.tsv"
  CHOWN_MODE="ok"
  CHOWN_FAIL_PATH=""
  WP_RC=0
  MV_MODE="real"
  MV_RACE_DONE="$CASE_DIR/mv-race-done"
  mkdir -p "$UPLOADS_DIR" "$QDIR/files" "$QDIR/rows"
  reset_logs
  : > "$OWN_DB"
}

# Truncates everything a single run writes, but not the ownership registry:
# the two-run cases need run 1's successful chowns to still be visible to
# run 2's stat, exactly as they would be on a real filesystem.
reset_logs() {
  : > "$LOG_FILE"; : > "$CHOWN_LOG"; : > "$CHOWN_TARGETS"; : > "$WP_LOG"
  rm -f "$MV_RACE_DONE"
}

# man <class> <rel> <att>   append a manifest line, same three tab-separated
# fields qmove writes ($rel is relative to $SITE_PATH).
man() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$QDIR/manifest.tsv"; }

# quarantined <rel> <content>   put a file in the quarantine set, as if qmove
# had moved it there.
quarantined() {
  mkdir -p "$(dirname "$QDIR/files/$1")"
  printf '%s\n' "$2" > "$QDIR/files/$1"
}

# at_site <rel> <content>   put a file where the restore would put it back,
# as a re-upload (a conflict) or as an entry an earlier run already restored.
at_site() {
  mkdir -p "$(dirname "$SITE_PATH/$1")"
  printf '%s\n' "$2" > "$SITE_PATH/$1"
}

rows() { printf 'INSERT INTO x VALUES (1);\n' > "$QDIR/rows/$1"; }

# owned_by <path> <owner:group>   seed the ownership registry. Anything not in
# it reads back as root:root, which is what a file the tool moved while
# running as root actually looks like.
owned_by() { printf '%s\t%s\n' "$1" "$2" >> "$OWN_DB"; }

# --------------------------------------------------------------- the stubs

chown() {
  local target
  for target in "$@"; do :; done          # the last argument is the path
  printf '%s\n' "$*" >> "$CHOWN_LOG"
  printf '%s\n' "$target" >> "$CHOWN_TARGETS"
  case "$CHOWN_MODE" in
    fail-all)  return 1 ;;
    fail-path) if [[ "$target" == "$CHOWN_FAIL_PATH" ]]; then return 1; fi ;;
  esac
  printf '%s\t%s\n' "$target" "$SITE_OWNER:$SITE_GROUP" >> "$OWN_DB"
  return 0
}

stat() {
  if [[ "${1:-}" == "-c" && "${2:-}" == "%U:%G" ]]; then
    local k v owner="root:root"
    while IFS=$'\t' read -r k v; do
      [[ "$k" == "${3:-}" ]] && owner="$v"
    done < "$OWN_DB"
    printf '%s\n' "$owner"
    return 0
  fi
  command stat "$@"
}

wp_run() {
  printf '%s\n' "$*" >> "$WP_LOG"
  return "$WP_RC"
}

# Real mv by default. In "race" mode the destination of the first move appears
# underneath it - a concurrent upload landing after the conflict scan and
# before the move - and then the real `mv -n` runs and silently declines to
# clobber it, exiting 0. That exit status is the whole trap.
mv() {
  if [[ "$MV_MODE" == "race" && ! -e "$MV_RACE_DONE" ]]; then
    local dest
    for dest in "$@"; do :; done
    mkdir -p "$(dirname "$dest")"
    printf 'CONCURRENT\n' > "$dest"
    : > "$MV_RACE_DONE"
  fi
  command mv "$@"
}

# --------------------------------------------------------------- observers

run_restore() { OUT="$(restore_site 2>&1)"; RC=$?; }

yesno()      { if "$@"; then echo yes; else echo no; fi; }
present()    { yesno test -e "$1"; }
content()    { cat "$1" 2>/dev/null; }
did_chown()  { yesno grep -Fxq -- "$1" "$CHOWN_TARGETS"; }
wp_called()  { yesno grep -Fq -- "$1" "$WP_LOG"; }
in_log()     { yesno grep -Fq -- "$1" "$LOG_FILE"; }
wp_calls()   { wc -l < "$WP_LOG" | tr -d ' '; }

# The success line and the sentence that follows it are what makes a false ok
# dangerous rather than merely wrong: it is the only place the tool tells the
# operator the quarantine set is now disposable.
SUCCESS_LINE="the quarantine set is left in place: remove it by hand"

# ============================================================== A. conflicts

new_case "A: a genuine conflict refuses, and moves nothing"
man attachment "wp-content/uploads/a.jpg"          11
man attachment "wp-content/uploads/a-150x150.jpg"  11
man orphan     "wp-content/uploads/existing.jpg"   0
quarantined "wp-content/uploads/a.jpg"         QUARANTINED-A
quarantined "wp-content/uploads/a-150x150.jpg" QUARANTINED-THUMB
quarantined "wp-content/uploads/existing.jpg"  QUARANTINED-OLD
at_site     "wp-content/uploads/existing.jpg"  REUPLOADED
rows posts.sql
run_restore

assert_eq        "A: returns non-zero"                 "1"   "$RC"
assert_contains  "A: names the conflicting path"       "conflict, already present: wp-content/uploads/existing.jpg" "$OUT"
assert_contains  "A: says the restore was aborted"     "restore aborted" "$OUT"
assert_not_contains "A: no success line"               "$SUCCESS_LINE" "$OUT"
assert_eq        "A: a.jpg was not moved out of quarantine"     "yes" "$(present "$QDIR/files/wp-content/uploads/a.jpg")"
assert_eq        "A: a.jpg did not land at the site"            "no"  "$(present "$SITE_PATH/wp-content/uploads/a.jpg")"
assert_eq        "A: the thumb was not moved either"            "yes" "$(present "$QDIR/files/wp-content/uploads/a-150x150.jpg")"
assert_eq        "A: the re-uploaded file was not clobbered"    "REUPLOADED" "$(content "$SITE_PATH/wp-content/uploads/existing.jpg")"
assert_eq        "A: rows were not imported (files first, and no files moved)" "0" "$(wp_calls)"
assert_eq        "A: nothing was chowned"                       "0" "$(wc -l < "$CHOWN_TARGETS" | tr -d ' ')"

# ================================================ B. partial restore resumes

new_case "B: a partially restored set finishes instead of false-aborting"
man attachment "wp-content/uploads/already.jpg" 21
man attachment "wp-content/uploads/pending.jpg" 22
at_site     "wp-content/uploads/already.jpg" ALREADY-BACK
quarantined "wp-content/uploads/pending.jpg" PENDING
rows posts.sql
run_restore

assert_eq        "B: succeeds"                          "0" "$RC"
assert_not_contains "B: reports no conflict"            "conflict" "$OUT"
assert_eq        "B: the pending file was moved back"   "PENDING" "$(content "$SITE_PATH/wp-content/uploads/pending.jpg")"
assert_eq        "B: the pending file left quarantine"  "no"  "$(present "$QDIR/files/wp-content/uploads/pending.jpg")"
assert_eq        "B: the already restored file is untouched" "ALREADY-BACK" "$(content "$SITE_PATH/wp-content/uploads/already.jpg")"
assert_eq        "B: the already restored file still gets its ownership re-applied" \
                 "yes" "$(did_chown "$SITE_PATH/wp-content/uploads/already.jpg")"
assert_eq        "B: the rows were imported"            "yes" "$(wp_called "posts.sql")"
assert_contains  "B: prints the success line"           "$SUCCESS_LINE" "$OUT"
# An already-restored entry must be recognised before mv is asked to move it,
# not by letting mv fail and reading the filesystem afterwards: the second way
# is also correct, and writes "mv: cannot stat ...: No such file or directory"
# into the operator's log once per entry on a wholly successful restore.
assert_eq        "B: no mv error noise in the operator's log" "no" "$(in_log "cannot stat")"
assert_eq        "B: nothing at all from mv in the log"       "no" "$(in_log "mv:")"

# ============================================== C. an already restored set

new_case "C: an already restored set re-applies ownership and imports rows"
man attachment "wp-content/uploads/2024/c.jpg" 31
at_site "wp-content/uploads/2024/c.jpg" ALREADY
rows posts.sql
rows postmeta.sql
run_restore

assert_eq        "C: succeeds"                       "0" "$RC"
assert_not_contains "C: reports no conflict"         "conflict" "$OUT"
assert_not_contains "C: reports no failed move"      "cannot restore" "$OUT"
assert_eq        "C: re-chowned the restored file"   "yes" "$(did_chown "$SITE_PATH/wp-content/uploads/2024/c.jpg")"
assert_eq        "C: re-chowned its directory too"   "yes" "$(did_chown "$SITE_PATH/wp-content/uploads/2024")"
assert_eq        "C: the rows were imported"         "yes" "$(wp_called "posts.sql")"
assert_contains  "C: prints the success line"        "$SUCCESS_LINE" "$OUT"
assert_eq        "C: no mv error noise in the operator's log" "no" "$(in_log "cannot stat")"

# ================================================== D. a move that fails

new_case "D: a file that cannot be moved back is a failure, not an ok"
# lost.jpg is in the manifest but its quarantined copy is gone and it is not
# at the site either: nothing to move, and the end state is not reached. It is
# listed FIRST on purpose - one unrecoverable entry must not abandon the rest
# of the set, which is the failure mode of "abort on the first problem".
man attachment "wp-content/uploads/lost.jpg" 42
man attachment "wp-content/uploads/good.jpg" 41
quarantined "wp-content/uploads/good.jpg" GOOD
rows posts.sql
run_restore

assert_eq        "D: returns non-zero"                "1" "$RC"
assert_contains  "D: names the file it could not restore" "cannot restore wp-content/uploads/lost.jpg" "$OUT"
assert_not_contains "D: no success line"              "$SUCCESS_LINE" "$OUT"
assert_not_contains "D: does not claim the set was restored" "restored $QDIR into" "$OUT"
assert_contains  "D: counts exactly one failure"      "finished with 1 failure(s)" "$OUT"
assert_contains  "D: the advice names the kind of problem" "could not be moved back" "$OUT"
assert_eq        "D: the healthy file was still restored" "GOOD" "$(content "$SITE_PATH/wp-content/uploads/good.jpg")"
assert_eq        "D: rows are still imported (files first, then rows)" "yes" "$(wp_called "posts.sql")"

# ================================================== E. the mv -n silent skip

new_case "E: mv -n exiting 0 on a silent skip is caught by the filesystem"
man attachment "wp-content/uploads/race.jpg" 51
quarantined "wp-content/uploads/race.jpg" QUARANTINED-RACE
rows posts.sql
MV_MODE="race"
run_restore

assert_eq        "E: returns non-zero"                "1" "$RC"
assert_contains  "E: reports the file as not restored" "cannot restore wp-content/uploads/race.jpg" "$OUT"
assert_not_contains "E: no success line"              "$SUCCESS_LINE" "$OUT"
assert_eq        "E: the concurrent upload was not clobbered" "CONCURRENT" "$(content "$SITE_PATH/wp-content/uploads/race.jpg")"
assert_eq        "E: the quarantined copy is still there"     "yes" "$(present "$QDIR/files/wp-content/uploads/race.jpg")"
assert_eq        "E: the skipped file was not chowned"        "no"  "$(did_chown "$SITE_PATH/wp-content/uploads/race.jpg")"

# ================================================== F. a row import that fails

new_case "F: a failed row import is a failure, and all three dumps are tried"
man attachment "wp-content/uploads/f.jpg" 61
quarantined "wp-content/uploads/f.jpg" F
rows posts.sql
rows postmeta.sql
rows thumb-postmeta.sql
WP_RC=1
run_restore

assert_eq        "F: returns non-zero"                "1" "$RC"
assert_contains  "F: names the dump it could not import" "cannot import posts.sql" "$OUT"
assert_contains  "F: counts all three failed imports"    "finished with 3 failure(s)" "$OUT"
assert_not_contains "F: no success line"              "$SUCCESS_LINE" "$OUT"
assert_contains  "F: the advice says a re-run retries the import" "retry the import" "$OUT"
assert_eq        "F: the file was still moved back (files first, then rows)" "F" "$(content "$SITE_PATH/wp-content/uploads/f.jpg")"
assert_eq        "F: postmeta.sql was tried too"      "yes" "$(wp_called "postmeta.sql")"
# thumb-postmeta.sql carries the pre-edit attachment metadata for attachments
# whose stale sizes were quarantined. Skipping it leaves those rows behind.
assert_eq        "F: thumb-postmeta.sql was tried too" "yes" "$(wp_called "thumb-postmeta.sql")"
# wp media regenerate would rewrite the metadata this import just restored,
# down to only the sizes the active theme currently registers.
assert_eq        "F: no wp media regenerate"          "no"  "$(wp_called "regenerate")"

# =========================================== G. a chown that fails on the file

new_case "G: a chown that fails on the restored file is a failure"
man attachment "wp-content/uploads/g.jpg" 71
quarantined "wp-content/uploads/g.jpg" G
rows posts.sql
CHOWN_MODE="fail-all"
run_restore

assert_eq        "G: returns non-zero"                "1" "$RC"
assert_contains  "G: names the file it could not chown" "cannot chown wp-content/uploads/g.jpg" "$OUT"
assert_not_contains "G: no success line"              "$SUCCESS_LINE" "$OUT"
assert_contains  "G: the advice says a re-run is safe" "re-running is safe and will retry it" "$OUT"
assert_eq        "G: the file was still moved back"   "G" "$(content "$SITE_PATH/wp-content/uploads/g.jpg")"

# ================================== H. a chown that fails on a directory, twice

new_case "H: a chown failing on an ancestor is retried by the next run"
man attachment "wp-content/uploads/2024/05/h.jpg" 81
quarantined "wp-content/uploads/2024/05/h.jpg" H
rows posts.sql
# The site's uploads directory exists and is already correct; 2024 and 2024/05
# do not exist yet, so this restore has to create them and hand them over.
owned_by "$UPLOADS_DIR" "$SITE_OWNER:$SITE_GROUP"
CHOWN_MODE="fail-path"
CHOWN_FAIL_PATH="$SITE_PATH/wp-content/uploads/2024"
run_restore

assert_eq        "H1: run 1 returns non-zero"            "1" "$RC"
assert_eq        "H1: run 1 chowned the restored file"   "yes" "$(did_chown "$SITE_PATH/wp-content/uploads/2024/05/h.jpg")"
assert_eq        "H1: run 1 chowned the 2024/05 ancestor" "yes" "$(did_chown "$SITE_PATH/wp-content/uploads/2024/05")"
assert_eq        "H1: run 1 tried the 2024 ancestor"     "yes" "$(did_chown "$SITE_PATH/wp-content/uploads/2024")"
assert_contains  "H1: run 1 names the directory it could not chown" "cannot chown $SITE_PATH/wp-content/uploads/2024 " "$OUT"
assert_not_contains "H1: run 1 prints no success line"   "$SUCCESS_LINE" "$OUT"
assert_eq        "H1: the file was moved back anyway"    "H" "$(content "$SITE_PATH/wp-content/uploads/2024/05/h.jpg")"
assert_eq        "H1: the uploads directory itself was never chowned" "no" "$(did_chown "$UPLOADS_DIR")"

# Run 2 is the point of this case. 2024/05 is now correctly owned (run 1 fixed
# it) but 2024 is still not (run 1 failed on it, and said so: "re-running is
# safe and will retry it"). A walk that stops at the first correctly-owned
# ancestor never reaches 2024 again, finds nothing to report, and prints ok
# and "remove it by hand" over a directory the site still cannot write to.
reset_logs
run_restore

assert_eq        "H2: run 2 still tries the 2024 ancestor" "yes" "$(did_chown "$SITE_PATH/wp-content/uploads/2024")"
assert_eq        "H2: run 2 returns non-zero"              "1" "$RC"
assert_contains  "H2: run 2 still names the directory"     "cannot chown $SITE_PATH/wp-content/uploads/2024 " "$OUT"
assert_not_contains "H2: run 2 prints no success line"     "$SUCCESS_LINE" "$OUT"
assert_not_contains "H2: run 2 reports no conflict"        "conflict" "$OUT"
assert_eq        "H2: run 2 left the restored file in place" "H" "$(content "$SITE_PATH/wp-content/uploads/2024/05/h.jpg")"

# ======================= I. a basedir with a trailing slash must not overshoot

# wp_get_upload_dir()'s basedir normally has no trailing slash, but the legacy
# upload_path option is copied through unchanged, so "uploads/" is reachable.
# The ancestor walk stops on containment, not on a string compare, because a
# string compare against "uploads/" never matches "uploads" and the walk runs
# straight past it into wp-content.
new_case "I: a trailing slash on basedir does not widen the chown"
UPLOADS_DIR="$SITE_PATH/wp-content/uploads/"
man attachment "wp-content/uploads/2024/i.jpg" 91
quarantined "wp-content/uploads/2024/i.jpg" I
rows posts.sql
run_restore

assert_eq        "I: succeeds"                        "0" "$RC"
assert_eq        "I: chowned the restored file"       "yes" "$(did_chown "$SITE_PATH/wp-content/uploads/2024/i.jpg")"
assert_eq        "I: chowned the directory it created" "yes" "$(did_chown "$SITE_PATH/wp-content/uploads/2024")"
assert_eq        "I: did NOT chown the uploads directory itself" "no" "$(did_chown "$SITE_PATH/wp-content/uploads")"
assert_eq        "I: did NOT chown wp-content"        "no" "$(did_chown "$SITE_PATH/wp-content")"
assert_eq        "I: did NOT chown the site root"     "no" "$(did_chown "$SITE_PATH")"

# ============================================== J. a malformed manifest line

# A manifest whose last line has no trailing newline is not just malformed:
# the plain `while read; do done < file` idiom drops such a line before the
# body runs at all, so it is invisible unless the loop is written to keep it.
new_case "J: a malformed manifest line is reported and counted"
man attachment "wp-content/uploads/j.jpg" 101
# A truncated final line: a class, no path, and no trailing newline. The
# plain `while read; do done < file` idiom drops such a line before the body
# runs at all, so it is invisible unless the loop keeps it; and once the loop
# does keep it, an unguarded empty $rel makes "$SITE_PATH/$rel" the site root,
# which exists, so the conflict check would report the whole site as taken.
printf 'orphan' >> "$QDIR/manifest.tsv"
quarantined "wp-content/uploads/j.jpg" J
rows posts.sql
run_restore

assert_eq        "J: returns non-zero"                "1" "$RC"
assert_contains  "J: warns about the malformed line"  "malformed manifest line" "$OUT"
assert_not_contains "J: no success line"              "$SUCCESS_LINE" "$OUT"
assert_contains  "J: the advice says a re-run will not fix it" "re-running will not fix them" "$OUT"
# The line recorded no path, so no move was ever attempted for it; blaming a
# move sends the operator to look in quarantine/files for a file that was
# never named.
assert_not_contains "J: does not blame a move that was never attempted" "could not be moved back" "$OUT"
assert_eq        "J: the well-formed entry was still restored" "J" "$(content "$SITE_PATH/wp-content/uploads/j.jpg")"
assert_eq        "J: an empty rel did not become a bogus conflict on \$SITE_PATH" \
                 "no" "$(yesno grep -q "conflict, already present: $" <<< "$OUT")"

# ================================== K. row dumps with no manifest at all

# quarantine_site's teardown removes an empty manifest.tsv and leaves a
# populated rows/ behind it (every file move failed, but the dumps already
# landed), so this combination is reachable and legitimate: there is simply
# nothing to move back.
new_case "K: a set with row dumps and no manifest is not an error"
rm -f "$QDIR/manifest.tsv"
rows posts.sql
rows postmeta.sql
rows thumb-postmeta.sql
run_restore

assert_eq        "K: succeeds"                        "0" "$RC"
assert_contains  "K: says why there is nothing to move" "nothing to move back" "$OUT"
assert_eq        "K: posts.sql imported"              "yes" "$(wp_called "posts.sql")"
assert_eq        "K: postmeta.sql imported"           "yes" "$(wp_called "postmeta.sql")"
assert_eq        "K: thumb-postmeta.sql imported"     "yes" "$(wp_called "thumb-postmeta.sql")"
assert_eq        "K: no wp media regenerate"          "no"  "$(wp_called "regenerate")"
assert_contains  "K: prints the success line"         "$SUCCESS_LINE" "$OUT"

new_case "K2: a zero-byte manifest behaves the same way"
: > "$QDIR/manifest.tsv"
rows posts.sql
run_restore

assert_eq        "K2: succeeds"                       "0" "$RC"
assert_eq        "K2: rows still imported"            "yes" "$(wp_called "posts.sql")"

# ============================================ L. a quarantine set that is not there

new_case "L: a stamp with no quarantine set is a failure"
RESTORE_STAMP="20991231-235959"
run_restore

assert_eq        "L: returns non-zero"                "1" "$RC"
assert_contains  "L: says which stamp is missing"     "no quarantine set 20991231-235959" "$OUT"
assert_not_contains "L: no success line"              "$SUCCESS_LINE" "$OUT"
assert_eq        "L: nothing was imported"            "0" "$(wp_calls)"

# ====================================== M. the stamp is validated before use

# $RESTORE_STAMP is interpolated straight into a path under $QUARANTINE_ROOT
# while running as root, so it is checked in parse_args, before restore_site
# ever builds a path from it. Run in a subshell: die() exits.
section "M: --restore validates the stamp before any path is built from it"
rc=0; ( parse_args --site example.com --restore '../../../etc' ) >/dev/null 2>&1 || rc=$?
assert_eq        "M: a traversal attempt is rejected" "1" "$rc"
rc=0; ( parse_args --site example.com --restore '2026-01-01' ) >/dev/null 2>&1 || rc=$?
assert_eq        "M: a wrong-shaped stamp is rejected" "1" "$rc"
rc=0; ( parse_args --site example.com --restore '20260101-000000' ) >/dev/null 2>&1 || rc=$?
assert_eq        "M: a real stamp is accepted"        "0" "$rc"
rc=0; ( parse_args --restore '20260101-000000' ) >/dev/null 2>&1 || rc=$?
assert_eq        "M: --restore without --site is rejected" "1" "$rc"

# ================================ N. a --site that matches nothing is a failure

# A filter matching no installation must not look like a successful no-op: the
# operator asked for a restore that never happened. load_site is stubbed out
# here because the real one needs wp-cli and a live database.
section "N: a --site matching no installation fails rather than doing nothing"
WWW_ROOT="$SANDBOX/nomatch"
mkdir -p "$WWW_ROOT/example.com"
: > "$WWW_ROOT/example.com/wp-config.php"
# shellcheck disable=SC2034  # SITE_NAME is read by for_each_site, not here
load_site() { SITE_NAME="example.com"; return 0; }
noop_site() { return 0; }

# shellcheck disable=SC2034  # ONLY_SITE and WWW_ROOT are read by for_each_site
ONLY_SITE="absent.example"
rc=0; for_each_site noop_site >/dev/null 2>&1 || rc=$?
assert_eq        "N: a non-matching --site returns non-zero" "1" "$rc"

# shellcheck disable=SC2034
ONLY_SITE="example.com"
rc=0; for_each_site noop_site >/dev/null 2>&1 || rc=$?
assert_eq        "N: a matching --site returns zero"         "0" "$rc"

# ---------------------------------------------------------------- summary

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
