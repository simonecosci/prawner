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

# ---------------------------------------------------------------- summary

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
